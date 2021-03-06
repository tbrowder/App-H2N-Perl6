#!/bin/bash
#
# This script runs under the ksh, POSIX, and bash shells.
#
shopt -qs extglob	# Uncomment this line if running under the bash shell.

USAGE="\
Usage: build-dns|check-dns|test-dns [[-c] [-f] [-q] [s] [-t]]\n\n\
       Builds, checks, or tests the site's DNS data that is generated\n\
       from the host table and \`spcl' files by the h2n program.\n\n\
       -c  check mode; build DNS data without reloading the name server\n\
       -f  force loading of all zones, changed or unchanged\n\
       -q  quiet mode; suppress displaying changed zones and archived files\n\
       -s  suppress copying of files to the named-test and archive-test\n\
           directories (effective in test mode only)\n\
       -t  test mode; build DNS data in an alternate directory using an\n\
                      alternate h2n program without reloading the name server\n\
       -?  display this message\n"

#
#   Title: build-dns
#  Author: Andris Kalnozols
#    Date: 8 May 2003
# Version: 3.96
#

#
# This script automates the detailed process of generating the DNS zone
# data of the domain(s) for which this name server is authoritative.
#
# The `h2n' program is used to create the DNS data from one or more
# host files.  Since `h2n' generates a complete set of DNS zone files
# with incremented serial numbers every time that it is run, even a small
# change like adding a CNAME to the forward-mapping zone can result in the
# needless transfer of hundreds of reverse-mapping zones to each slave
# name server.
#
# This version of the `build-dns' script eliminates the unnecessary
# transfer of unchanged zones by comparing each new zone data file in
# the build directory with the current version of the zone in the
# name server's operational directory.  Nested `$INCLUDE' files are
# also compared.  If the only difference is an incremented serial
# number, the current zone data file is *not* replaced.
#

#
# Global variable declarations for subsequent function definitions.
#

typeset dot forward_domain forward_zone_file base_net last_octet
typeset -i default_cidr_size default_num_zones num_zones


##########################################################################
#
function get_cidr_size
{
  #
  # This function returns the CIDR size that corresponds
  # to a given network mask.
  #
  # NOTE: Since the function's result is printed to STDOUT,
  #       the caller must capture this value with the `$(...)'
  #       command substitution construct.
  #
  # Parameter:  $1 ... network mask
  #

  typeset netmask tmp
  typeset -i cidr_size i octet[2] octet_bits

  netmask=${1#*.}			# remove the mask's first octet
  ((octet[0] = ${netmask%%.*}))		# isolate the mask's second octet
  tmp=${netmask#*.}
  ((octet[1] = ${tmp%.*}))		# isolate the mask's third octet
  ((octet[2] = ${netmask##*.}))		# isolate the mask's fourth octet
  ((cidr_size = 8))			# valid `h2n' networks are /8 to /32
  for i in 0 1 2
  do
    if ((octet[i] != 0))
    then
      ((octet_bits = 8))
      while (((octet[i] % 2) != 1))	# loop until the right-most mask bit is
      do				# shifted into the Least Significant Bit
	((octet[i] >>= 1))		# right-shift by 1 bit
	((octet_bits -= 1))		# and account for it
      done
      ((cidr_size += octet_bits))	# accumulate the contiguous bit count
    fi
  done
  echo $cidr_size

  return 0
}
#
##########################################################################


##########################################################################
#
function get_num_zones
{
  #
  # This function returns the number of class A, B, or C network
  # zone files that correspond to a given CIDR size.
  #
  # NOTE: Since the function's result is printed to STDOUT,
  #       the caller must capture this value with the `$(...)'
  #       command substitution construct.
  #
  # Parameter:  $1 ... CIDR size
  #

  typeset -i network_zone_files

  if (($1 == 8)) || (($1 == 16)) || (($1 >= 24))
  then
    ((network_zone_files = 1))
  else
    if (($1 < 16))
    then
      ((network_zone_files = (1 << (16 - $1))))
    else
      ((network_zone_files = (1 << (24 - $1))))
    fi
  fi
  echo $network_zone_files

  return 0
}
#
##########################################################################


##########################################################################
#
function set_default_network_size
{
  #
  # This function sets the following global integer variables based
  # on the network CIDR size or mask that is passed as the parameter:
  #
  #   default_cidr_size
  #   default_num_zones
  #
  # Parameter:  $1 ... network CIDR size or mask
  #                    NOTE: A string containing the `-N' option
  #                          from an `h2n' options file may
  #                          also be passed as a value.
  #

  typeset default_cidr_or_mask

  if [[ $1 = '-N' ]]
  then
    default_cidr_or_mask=$2
  else
    default_cidr_or_mask=$1
  fi
  #
  # Make sure to trim the leading "/" of a CIDR size.
  #
  default_cidr_or_mask=${default_cidr_or_mask#/}

  if [[ $default_cidr_or_mask = '255.'* ]]
  then
    ((default_cidr_size = $(get_cidr_size $default_cidr_or_mask)))
  else
    ((default_cidr_size = $default_cidr_or_mask))
  fi
  ((default_num_zones = $(get_num_zones $default_cidr_size)))

  return 0
}
#
##########################################################################


##########################################################################
#
function parse_d_option
{
  #
  # This function parses the `-d' option obtained from an `h2n'
  # options file and sets the following global variables:
  #
  #   forward_domain    ... first argument of the `-d' option
  #   forward_zone_file ... default filename computed from `forward_domain' or
  #                         passed filename from the optional `db=' argument
  #
  # This is necessary for identifying a `-n' option for a sub-class-C
  # network which maps PTR records back to the forward-mapping domain.
  # Such `-n' options can be effectively ignored.
  #
  # Parameter:  $@ ... `-d' option
  #

  typeset -i num_parms

  forward_domain=${2%%+(.)}			# trim any trailing dot(s)
  while [[ $forward_domain = *'\\\\'* ]]
  do
    # Remove redundant escape characters.
    #
    forward_domain=$(printf "%s\n" "$forward_domain" | sed -e 's/\\\\/\\/g')
  done
  forward_domain=$(printf "%s\n" "$forward_domain" | \
		   awk '{ print tolower($0) }')
  forward_zone_file="db.${forward_domain%%.*}"	# set default

  shift 2
  while (($# > 0))
  do
    if [[ $1 = 'db='* ]]
    then
      forward_zone_file=${1#db=}		# override the default
      ((num_parms = $#))
      shift $num_parms
    else
      shift 1
    fi
  done

  return 0
}
#
##########################################################################


##########################################################################
#
function parse_n_option
{
  #
  # This function parses a `-n' option obtained from an `h2n'
  # options file and sets the following global variables:
  #
  #   For /8 to /24 networks:
  #     -n WW[.XX[.YY]][/CIDRsize|:netmask]
  #
  #   base_net   = WW    for CIDR sizes /8  through /16
  #   base_net   = WW.XX for CIDR sizes /17 through /24
  #   dot        = ""    for CIDR size  /8
  #              = "."   for CIDR sizes /9  through /24
  #   last_octet = ""    for CIDR size  /8
  #              = XX    for CIDR sizes /9  through /16
  #              = YY    for CIDR sizes /17 through /24
  #
  #   ........................
  #
  #   For /25 to /32 networks:
  #     -n WW.XX.YY.ZZ[/CIDRsize|:netmask] domain=DNS-domain-name ptr-owner=...
  #
  #   base_net   = WW.XX.YY.ZZ-LL (default for /25-31, LL=last IP in range)
  #              = WW.XX.YY.ZZ    (default for /32)
  #              = DNS file-name  (derived filename from the `domain=' argument)
  #              = ""             (if `domain=' is the forward-mapping domain)
  #   dot        = ""
  #   last_octet = ""
  #
  #   ........................
  #
  #   num_zones  = global variable `default_num_zones' unless
  #                an optional CIDRsize/netmask is specified.
  #
  # Parameter:  $@ ... `-n' option
  #

  typeset netmask network domain_arg domain_label lc_domain_arg temp_domain_arg
  typeset -i cidr_size last_host_addr range

  if [[ $2 = *@([/:])* ]]
  then
    # Isolate the network-specific CIDR size or mask.
    #
    network=${2%@([/:])*}
    if [[ $2 = *':'* ]]
    then
      netmask=${2#*:}
      ((cidr_size = $(get_cidr_size $netmask)))
    else
      ((cidr_size = ${2#*/}))
    fi
    ((num_zones = $(get_num_zones $cidr_size)))
  else
    network=$2
    ((cidr_size = default_cidr_size))
    ((num_zones = default_num_zones))
  fi

  if ((cidr_size <= 24))
  then
    while [[ $network != +([0-9])'.'+([0-9])'.'+([0-9])'.0' ]]
    do
      #
      # Normalize the network specification to four octets
      # since the `h2n' options file may have network
      # specifications appearing with and/or without trailing
      # zeros.
      #
      network="$network.0"
    done
    network=${network%.0}		# standardize to three octets
    if ((cidr_size == 8))
    then
      base_net=${network%%.*}		# set to to first octet
      dot=""
      last_octet=""
    elif ((cidr_size <= 16))
    then
      base_net=${network%%.*}		# set to the first octet
      dot="."
      last_octet=${network#*.}
      last_octet=${last_octet%.*}	# set to the second octet
    else
      base_net=${network%.*}		# set to the first two octets
      dot="."
      last_octet=${network##*.}		# set to the third octet
    fi
  else
    #
    # Look for an optional `domain=' argument that is only valid
    # for an `-n' option specifying a network of size /25 to /32.
    # The "$dot" and "$last_octet" global variables are not used and
    # are set to the null string.
    #
    domain_arg=""
    dot=""
    last_octet=""
    shift 2
    while (($# > 0))
    do
      if [[ $1 = 'domain='* ]]
      then
	domain_arg=${1#domain=}
	domain_arg=${domain_arg%%+(.)}		# trim any trailing dot(s)
	((num_parms = $#))
	shift $num_parms
      else
	shift 1
      fi
    done
    if [[ -n $domain_arg ]]
    then
      while [[ $domain_arg = *'\\\\'* ]]
      do
	# Remove redundant escape characters.
	#
	domain_arg=$(printf "%s\n" "$domain_arg" | sed -e 's/\\\\/\\/g')
      done
      lc_domain_arg=$(printf "%s\n" "$domain_arg" | awk '{ print tolower($0) }')
      if [[ $lc_domain_arg = $forward_domain ]]
      then
	#
	# The reverse-mapping data was written to the forward-mapping
	# zone file.  Set the octet-related global variable to the
	# null string to effectively skip this `-n' option.
	#
	base_net=""
      else
	if [[ $domain_arg = *'.in-addr.arpa' ]]
	then
	  #
	  # Construct the corresponding zone filename by stripping the
	  # `.in-addr.arpa' labels and reversing the remaining labels.
	  #
	  domain_arg=${domain_arg%.in-addr.arpa}
	  temp_domain_arg=""
	  while [[ -n $domain_arg ]]
	  do
	    domain_label=${domain_arg##*[!\\].}
	    if [[ $domain_label = $domain_arg ]]
	    then
	      #
	      # The last label has been reached.  If the network's CIDR
	      # size is part of the domain name, make sure to accommodate
	      # the following adjustment:
	      #
	      #   28/80.254.153.156.in-addr.arpa
	      #            becomes
	      #       156.153.254.28/80
	      #          adjusted to
	      #       156.153.254.80/28
	      #
	      if [[ $domain_arg = $cidr_size'/'?* ]]
	      then
		domain_label=${domain_arg#*/}
		domain_label="$domain_label/$cidr_size"
		domain_arg=""
	      fi
	    fi
	    temp_domain_arg="$temp_domain_arg.$domain_label"
	    domain_arg=${domain_arg%%?(.)$domain_label?(.)}
	  done
	  domain_arg=${temp_domain_arg#.}
	fi
	#
	# Massage the domain name into a suitable zone filename.
	#
	while [[ $domain_arg = *'\\'+([\$@])* ]]
	do
	  # Unescape the "$" and "@" characters.
	  #
	  domain_arg=$(printf "%s\n" "$domain_arg" | sed -e 's/\\\([$@]\)/\1/g')
	done
	while [[ $domain_arg = *+([/<|>&[()\$?;\'\`])* ]]
	do
	  # Convert characters that would cause trouble in a filename
	  # to a harmless "%" character.
	  #
	  domain_arg=$(printf "%s\n" "$domain_arg" | \
		       sed -e "s/[/<|>&[()\$?;'\`]/%/g")
	done
	#
	# Convert escaped whitespace to underscore characters and then
	# get rid of any remaining escape characters since they no
	# longer serve any purpose.
	#
	domain_arg=$(printf "%s\n" "$domain_arg" | \
		     sed -e 's/\\[ 	]/_/g;s/\\//g')
	base_net=$domain_arg
      fi
    else
      #
      # Compute the default filename based on the range of IP
      # addresses that correspond to the network's CIDR size.
      # Examples: -n 156.153.254.80/32  -->  db.156.153.254.80
      #           -n 156.153.254.80/28  -->  db.156.153.254.80-95
      #
      if ((cidr_size == 32))
      then
	base_net=$network			# the simplest case
      else
	((range = (1 << (32 - cidr_size))))
	((last_host_addr = (${network##*.} + range - 1)))
	base_net="$network-$last_host_addr"
      fi
    fi
  fi

  return 0
}
#
##########################################################################


##########################################################################
#
function copy_zone_files
{
  #
  # This function copies zone files between the `named' data
  # directory and the current directory in which this script
  # does its work.
  #
  # Parameters:  $1 ... "in" or "out"
  #			"in" means files are copied into the current
  #			working directory from the `named' directory
  #			specified in the `/etc/named.conf' file.
  #			"out" is the other way around.
  #
  #		 $2 ... The `h2n' options file from which the networks
  #			will be extracted to determine which reverse-mapping
  #			zone files to copy.
  #
  #		 $3 ... Flag to control whether or not to copy the
  #			forward-mapping zone file from the `-d' option.
  #

  typeset -i i
  typeset copy_direction forward_zone_flag options_filename option_line \
	  source_dir target_dir zone_file

  copy_direction=$1
  if [[ $copy_direction = 'in' ]]
  then
    source_dir=$NAMED_DIR
    target_dir=$BUILD_DIR
  else
    source_dir=$BUILD_DIR
    target_dir=$NAMED_DIR
  fi
  options_filename=$2
  if [[ $3 = *true ]]
  then
    forward_zone_flag=true
  else
    forward_zone_flag=false
  fi

  # IMPORTANT: Set the default netmask in case there is no `-N' option
  #            contained in the passed options file.
  #
  set_default_network_size /24
  while read -r option_line
  do
    # Read the `h2n' options file and look for any `-d/-N/-n' options.
    #
    if [[ $option_line = *(" "|"	")-d+(" "|"	")* ]]
    then
      parse_d_option $option_line	# get forward-mapping domain & filename
    elif [[ $option_line = *(" "|"	")-N+(" "|"	")* ]]
    then
      set_default_network_size $option_line
    elif [[ $option_line = *(" "|"	")-n+(" "|"	")* ]]
    then
      parse_n_option $option_line	# initialize octet-related variables
      ((i = 1))
      while ((i <= num_zones))
      do
	zone_file="db.$base_net$dot$last_octet"
	if [[ $zone_file != 'db.' ]] && \
	   ([[ $copy_direction = 'in' || $force_update = true ]] || \
	    compare_data $zone_file archive_false checkSOA_true)
	then
	  #
	  # (Un)conditionally copy the zone data files between the
	  # source and target directories.
	  #
	  if [[ ! ( $check_mode = true && $copy_direction = 'out' ) ]]
	  then
	    cp -p $source_dir/$zone_file $target_dir/ 2> /dev/null
	  fi
	  if [[ $copy_direction = 'in' ]]
	  then
	    #
	    # Make sure to copy any `.log' or `.jnl' files so that `h2n'
	    # can spot dynamic zones and avoid accidental data loss.
	    #
	    cp -p $source_dir/$zone_file.[lj][on][gl] $target_dir/ 2> /dev/null
	  else
	    if [[ $verbose = true ]]
	    then
	      echo "  $zone_file"
	    fi
	    ((updated_zones += 1))
	  fi
	fi
	if ((num_zones > 1))
	then
	  ((last_octet += 1))
	fi
	((i += 1))
      done
    fi
  done < $options_filename

  if [[ $forward_zone_flag = true ]]
  then
    if [[ $copy_direction = 'in' || $force_update = true ]] || \
       compare_data $forward_zone_file archive_false checkSOA_true
    then
      #
      # (Un)conditionally copy the zone data file between the
      # source and target directories.
      #
      if [[ ! ( $check_mode = true && $copy_direction = 'out' ) ]]
      then
        cp -p $source_dir/$forward_zone_file $target_dir/ 2> /dev/null
      fi
      if [[ $copy_direction = 'in' ]]
      then
        #
        # Make sure to copy any `.log' or `.jnl' files so that `h2n'
        # can spot dynamic zones and avoid accidental data loss.
        #
        cp -p $source_dir/$forward_zone_file.[lj][on][gl] \
	      $target_dir/ 2> /dev/null
      else
	if [[ $verbose = true ]]
	then
	  echo "  $forward_zone_file"
	fi
	((updated_zones += 1))
      fi
    fi
  fi

  return 0
}
#
##########################################################################


##########################################################################
#
function compare_data
{
  #
  # This function compares two BIND zone files or two data files
  # and returns an exit status based on the following conditions:
  #
  #   0     Files are not identical.		(TRUE if tested)
  #   1     Files are (functionally) identical.	(FALSE if tested)
  #
  # If necessary, the passed filename will be compared with its most
  # recent copy (`filename_01') in the archive directory.  If the files
  # are different and the archive flag is set, each `filename_n' is
  # renamed to `filename_n+1' up to the maximum number of archives
  # ($MAX_ARCHIVES).  The passed filename is then copied to `filename_01'.
  #
  # Parameters:  $1 ... Common filename of the two entities to be compared.
  #
  #		 $2 ... Required flag indicating whether or not the filename
  #			should be archived if a comparison shows that it has
  #			changed.
  #
  #		 $3 ... Optional flag indicating that a special comparison
  #			of SOA resource records in each file is to be done.
  #

  typeset -i exit_status i index local_status num_lines serial
  typeset filename archive_flag checkSOA_flag nested_filename SOA_diff_passed

  filename=$1
  if [[ $2 = *true ]]
  then
    archive_flag=true
  else
    archive_flag=false
  fi
  if (($# == 3))
  then
    if [[ $3 = *true ]]
    then
      checkSOA_flag=true
    else
      checkSOA_flag=false
    fi
  else
    checkSOA_flag=false
  fi
  ((exit_status = 1))		# assume equivalency unless proven otherwise

  if [[ ! -f $filename ]]
  then
    #
    echo >&2
    echo "ERROR: The file \`$filename' does not exist." >&2
    return 0
    #
  elif [[ $checkSOA_flag = true ]]
  then
    SOA_diff_passed=false	# assume non-equivalency unless proven otherwise
    if [[ $archive_flag = true ]]
    then
      SOURCE_DIR=$ARCHIVE_DIR
      src_file=${filename}_01
    else
      SOURCE_DIR=$NAMED_DIR
      src_file=$filename
    fi
    #
    # Check for the possibility that a new zone has just been
    # created in the build directory which does not yet exist
    # in the name server's operational directory or, if archiving
    # is in effect, the archive directory.
    #
    if [[ ! -f $SOURCE_DIR/$src_file ]]
    then
      if [[ $archive_flag = false ]]
      then
	#
	# Force the zone file to be copied to the operational directory.
	#
	return 0
      else
	#
	# Although there is nothing more to do regarding the comparison
	# of SOA records, set the inequality flag and resume processing
	# when the section that searches for $INCLUDE files is reached.
	#
	((exit_status = 0))
      fi
    else
      #
      # Compare the SOA record in the zone data file in the source directory
      # with that in the identically-named file in the build directory.
      # If the only difference is that the newly-built version has a serial
      # number which is one greater than the current version in the source
      # directory, then the files will be considered functionally identical
      # unless subsequent inspections of any embedded $INCLUDE directives
      # reveal a difference.
      #
      diff $SOURCE_DIR/$src_file $BUILD_DIR/$filename 2> /tmp/stderr.out_$$ | \
	grep '^[\<\>]' > /tmp/SOA_RRs_$$
      if [[ -s /tmp/stderr.out_$$ ]]
      then
	#
	# Report the error.
	#
	cat <<-EOM >&2

	WARNING: The diff(1) command produced the following message while trying
	         to compare the versions of file \`$filename':

	EOM
	cat /tmp/stderr.out_$$ >&2
	echo >&2
	echo "The requested comparison of this file was not done." >&2
	echo >&2
	rm /tmp/stderr.out_$$ /tmp/SOA_RRs_$$
	return 0
      else
	rm /tmp/stderr.out_$$
	((num_lines = $(cat /tmp/SOA_RRs_$$ | wc -l)))
	if ((num_lines != 2))
	then
	  #
	  # The two zone data files are either identical or differ
	  # by more than just their respective SOA records.
	  #
	  rm /tmp/SOA_RRs_$$
	  if ((num_lines == 0))
	  then
	    SOA_diff_passed=true
	  else
	    if [[ $archive_flag = false ]]
	    then
	      #
	      # Force the zone file to be copied to the operational directory.
	      #
	      return 0
	    else
	      #
	      # Although there is nothing more to do regarding the comparison
	      # of SOA records, set the inequality flag and resume processing
	      # when the section that searches for $INCLUDE files is reached.
	      #
	      ((exit_status = 0))
	    fi
	  fi
	else
	  #
	  # The temporary file holding the two SOA records should be
	  # formatted according to the following example if both of
	  # the original zone files were built by the `h2n' program:
	  #
	  # < @     SOA  hplns3 hostmaster ( 2314 3h 1h 1w 10m )
	  # > @     SOA  hplns3 hostmaster ( 2315 3h 1h 1w 10m )
	  #
	  # In order to consider the SOA records as functionally
	  # equivalent so that further inspections can be made,
	  # the only allowed difference is that the serial number
	  # in the build directory version is one greater than
	  # the version in the source directory.
	  #
	  first_line=true
	  while read -r SOA_RR
	  do
	    set -- $SOA_RR	# parse into whitespace-delimited tokens
	    if (($# != 12))
	    then
	      #
	      # Deal with the unexpected format by simply regarding
	      # the two zone data files as different.
	      #
	      ((exit_status = 0))
	      break
	    elif [[ $first_line = true ]]
	    then
	      zone=$2
	      rrtype=$3
	      mname=$4
	      rname=$5
	      ((serial = $7))
	      refresh=$8
	      retry=${9}
	      expire=${10}
	      negcache=${11}
	      first_line=false
	    elif [[ $zone != $2 ]]	|| [[ $rrtype != $3 ]]	  || \
		 [[ $mname != $4 ]]	|| [[ $rname != $5 ]]	  || \
		 ((serial != ($7 - 1)))	|| [[ $refresh != $8 ]]	  || \
		 [[ $retry != ${9} ]]	|| [[ $expire != ${10} ]] || \
		 [[ $negcache != ${11} ]]
	    then
	      #
	      # The two zone data files differ by more than an
	      # incremented serial number between their respective
	      # SOA records.
	      #
	      ((exit_status = 0))
	    fi
	  done < /tmp/SOA_RRs_$$
	  set --
	  rm /tmp/SOA_RRs_$$
	  if ((exit_status == 0))
	  then
	    if [[ $archive_flag = false ]]
	    then
	      #
	      # Force the zone file to be copied to the operational directory.
	      #
	      return 0
	    fi
	  else
	    SOA_diff_passed=true
	  fi
	fi
      fi
    fi
  fi

  # Look for all "$INCLUDE" statements that the passed file might
  # contain and call ourself recursively for each one that is found.
  #
  if grep '^\$INCLUDE[	 ]' $filename > /tmp/include_files_$$
  then
    #
    # Read the list of included filenames and insert the name of each
    # one into the local array "$nested_filename".  In order to minimize
    # the number of open file descriptors and to permit the use of a
    # common temporary file, any recursive calls are made after the
    # temporary file is read, closed, and removed.
    #
    ((index = -1))
    while read -r include_line
    do
      include_file=${include_line##\$INCLUDE+(	| )}
      include_file=${include_file%%+(	| )*}
      ((index += 1))
      nested_filename[index]=$include_file
    done < /tmp/include_files_$$
    rm /tmp/include_files_$$
    #
    # Now make the recursive call(s)
    #
    ((i = 0))
    while ((i <= index))
    do
      # NOTE: At this point, we are checking `spcl' and other included
      #	      files which contain no SOA record (if utilized by the
      #       `h2n' program).  Therefore, make sure to disable SOA
      #       comparisons for all recursive calls.
      #
      compare_data ${nested_filename[i]} $archive_flag checkSOA_false
      ((local_status = $?))
      if ((local_status == 0))
      then
	if [[ $archive_flag = false ]]
	then
	  #
	  # If a file difference was found and the `$archive_flag' is
	  # false, we can return immediately to this function's caller.
	  #
	  return 0
	else
	  #
	  # Make sure to maintain an accurate accounting of the
	  # exit status that this function will ultimately return.
	  #
	  ((exit_status = 0))
	fi
      fi
      ((i += 1))
    done
  else
    rm /tmp/include_files_$$
  fi

  #
  # This block is reached after all included files have been recursively
  # compared (and possibly archived) or if the passed filename contained
  # no included files.
  #
  if [[ $checkSOA_flag = true && $archive_flag = false ]]
  then
    #
    # We are (back) at the original function call after processing
    # any included files that may have been present.  Since any
    # discovered zone data difference would have caused an immediate
    # return from this function, the fact that we are here means
    # that the zone files are functionally identical.
    #
    return 1
  fi

  #
  # The last section of this function deals exclusively
  # with managing the archive directory.
  #
  uq_filename=${filename##*/}
  if [[ ! -f $ARCHIVE_DIR/${uq_filename}_01 ]]
  then
    #
    # This is a new file that will join the archive directory.
    #
    if [[ $archive_flag = true ]]
    then
      if [[ $check_mode = false ]]
      then
	cp -p $filename $ARCHIVE_DIR/${uq_filename}_01
      fi
      if [[ $verbose = true ]]
      then
	echo "  $uq_filename"
      fi
      ((archived_files += 1))
    fi
    ((exit_status = 0))
  else
    if [[ $checkSOA_flag = true ]]
    then
      #
      # Use the results of the previous diff(1)/SOA comparison
      # to decide if the zone data file needs to be archived.
      #
      if [[ $SOA_diff_passed = true ]]
      then
	((local_status = 0))
      else
	((local_status = 1))
      fi
    else
      #
      # See if the passed filename differs from its most
      # recent predecessor in the archive directory.
      #
      cmp -s $filename $ARCHIVE_DIR/${uq_filename}_01  > /dev/null \
						      2> /tmp/stderr.out_$$
      ((local_status = $?))
      if ((local_status > 1))
      then
	#
	# Report the error.
	#
	cat <<-EOM >&2

	WARNING: The cmp(1) command produced the following message while trying
	         to archive the file \`$filename':

	EOM
	cat /tmp/stderr.out_$$ >&2
	echo >&2
	echo "The requested archiving of this file was not done." >&2
	echo >&2
	((exit_status = 0))
      fi
      rm /tmp/stderr.out_$$
    fi
    if ((local_status == 1))
    then
      #
      # The files differ.
      #
      if [[ $archive_flag = true ]]
      then
	if [[ $check_mode = false ]]
	then
	  #
	  # Proceed with the archiving process.
	  #
	  ((earlier_one = $MAX_ARCHIVES))
	  while ((earlier_one > 1))
	  do
	    ((this_one = earlier_one - 1))
	    if ((this_one < 10))
	    then
	      this_one="0"$this_one
	    fi
	    mv $ARCHIVE_DIR/${uq_filename}_$this_one \
	       $ARCHIVE_DIR/${uq_filename}_$earlier_one 2> /dev/null
	    earlier_one=$this_one
	  done
	  cp -p $filename $ARCHIVE_DIR/${uq_filename}_01
	fi
	if [[ $verbose = true ]]
	then
	  echo "  $uq_filename"
	fi
	((archived_files += 1))
      fi
      ((exit_status = 0))
    fi
  fi

  return $exit_status
}
#
##########################################################################


#
# Global variable initialization
#

typeset -i archived_files start_line updated_zones

check_mode=false
test_mode=false
force_update=false
verbose=true
skip_file_copy=false
reload_named=false
mode_comment=""
((archived_files = 0))
((updated_zones = 0))

# Parse the argument vector passed to this script
# to determine the desired operating mode.
#
while getopts :cfqst arguments
do
	case $arguments in
		c)  # Run in `check-dns' mode.
		    #
		    check_mode=true
		    mode_comment=" (check mode)";;
		f)  # Force posting of all zones, changed or unchanged.
		    #
		    force_update=true;;
		q)  # Suppress displaying changed zones and archived files.
		    #
		    verbose=false;;
		s)  # Suppress copying of files to the named and archive
		    # directories (effective in test mode only).
		    #
		    skip_file_copy=true;;
		t)  # Run in `test-dns' mode.
		    #
		    test_mode=true
		    mode_comment=" (test mode)";;
		*)  IFS=""	# preserve contiguous whitespace
		    if [[ $OPTARG = "?" ]]
		    then
		      #
		      # Display usage information.
		      #
		      printf "%b\n" "$USAGE"
		      exit 0
		    elif [[ $OPTARG != \+* ]]
		    then
		      #
		      # Make a cosmetic change to `$OPTARG'.
		      #
		      OPTARG="-$OPTARG"
		    fi
		    echo "Invalid argument: \`$OPTARG'." >&2
		    printf "%b\n" "$USAGE" >&2
		    exit 2;;
	esac
done

# The alternate names by which this script can be
# run override the corresponding vector arguments.
#
program_name=${0##*/}
if [[ $program_name = "check-dns" ]]
then
  check_mode=true
  mode_comment=""
elif [[ $program_name = "test-dns" ]]
then
  test_mode=true
  mode_comment=""
fi


##################  Begin site-specific customizations  ###################

# This sed(1) routine should extract the correct directory
# but your mileage may vary depending on how the `options'
# statement is formatted.  Hardcoding is always available.
#
NAMED_DIR=$(sed -n -e '/^options /,/^[	 ]*};[	 ]*$/{'\
		   -e '/directory/{'\
		   -e 's/.*directory[^"]*["]//;s/["].*//p'\
		   -e '}'\
		   -e '}' /etc/named.conf)
JOB_TITLE="DNS BUILD"
BUILD_DIR=/var/named/data
ARCHIVE_DIR=$BUILD_DIR/archive
H2N_PROGRAM=/usr/local/bin/h2n
LOGFILE=syslog.log
SYSLOG=/var/adm/syslog/$LOGFILE
MODE=build
NDC=/usr/sbin/ndc
START_BIND9=/usr/sbin/named
USING_BIND9=false

if [[ $check_mode = true && $test_mode = true ]]
then
  mode_comment=" (h2n check mode)"
  JOB_TITLE="h2n CHECK"
  H2N_PROGRAM=/usr/local/bin/h2n.test
  MODE=check
elif [[ $check_mode = true ]]
then
  JOB_TITLE="DNS CHECK"
  MODE=check
elif [[ $test_mode = true ]]
then
  JOB_TITLE="DNS TEST"
  BUILD_DIR=/var/named/test
  NAMED_DIR=$BUILD_DIR/zone
  ARCHIVE_DIR=$BUILD_DIR/archive
  H2N_PROGRAM=/usr/local/bin/h2n.test
  MODE=test
fi

# The following variable initializations serve two purposes:
#
#   1. Establishing a checking mechanism for filenames which
#      *must* be present in order for this script to proceed.
#
#   2. A declaration mechanism for controlling which files get
#      archived and how many versions of each to keep.
#
# NOTE 1: It is not strictly necessary to specify any `spcl.*' files
#         in these initializations.  Since the `h2n' program creates
#         references to these files via "$INCLUDE" directives in the
#         zone data files, the archiving function will automatically
#         detect and archive the forward-mapping `spcl.*' files plus
#         all nested files as long as the forward-mapping zone data
#         files themselves are archived.  The `spcl.*' files for
#         reverse-mapping zone data are archived along with the
#         `h2n' options file(s).
#
# NOTE 2: If you want to archive any of the "db." zone files that
#         `h2n' generates, make sure to also initialize the
#         "CREATED_FILES" variable with these file names.
#         Otherwise, the check for required files might fail.
#
domain_1_passed=false			# `h2n' pass/fail status flags for
domain_2_passed=false			# each domain that this script builds

MAX_ARCHIVES=10				# number of file versions to keep
OPTION_FILE_PATTERN="options.*"		# shell pattern that identifies
					# all `h2n' option files.
DOMAIN_1_FILES="hosts  options.domain-1  spcl.domain-1  db.domain-1"
DOMAIN_2_FILES="options.domain-2  spcl.domain-2  db.domain-2"
CREATED_FILES="db.domain-1  db.domain-2"

###################  End site-specific customizations  ####################


#
# Trap any termination signals that might be received
# and perform some clean-up before exiting this script.
#
trap 'rm /tmp/$MODE-dns.* /tmp/*_$$ 2> /dev/null;\
      echo >&2
      echo "Received SIGHUP signal - terminating abnormally." >&2;\
      echo >&2
      exit 2' HUP
trap 'rm /tmp/$MODE-dns.* /tmp/*_$$ 2> /dev/null;\
      echo >&2
      echo "Received SIGINT signal - terminating abnormally." >&2;\
      echo >&2
      exit 2' INT
trap 'rm /tmp/$MODE-dns.* /tmp/*_$$ 2> /dev/null;\
      echo >&2
      echo "Received SIGQUIT signal - terminating abnormally."; >&2\
      echo >&2
      exit 2' QUIT
trap 'rm /tmp/$MODE-dns.* /tmp/*_$$ 2> /dev/null;\
      echo >&2
      echo "Received SIGTERM signal - terminating abnormally."; >&2\
      echo >&2
      exit 2' TERM

cd $BUILD_DIR

#
# First, check for the existence of the lock file
# that this script builds.  If it exists, then this
# script is being run elsewhere and we should not
# proceed further.
#
if [[ -f /tmp/$MODE-dns.lock ]]
then
  #
  echo >&2
  echo "The file \`/tmp/$MODE-dns.lock' already exists." >&2
  echo "Either another process is running \`$program_name'" >&2
  echo "or the lock file needs to be manually removed." >&2
  echo >&2
  exit 2
else
  touch /tmp/$MODE-dns.lock
fi

echo
echo "----- \`$program_name'$mode_comment starting at $(date)."
echo

#
# Check for the full set of required files before proceeding.
#
for file in $CREATED_FILES
do
  if [[ ! -f $file ]]
  then
    #
    # In order to pass the upcoming fileset completeness check,
    # pre-create the files which this script will create anyway.
    #
    touch $file
  fi
done
error=false
for file in $DOMAIN_1_FILES $DOMAIN_2_FILES
do
  if [[ ! -f $file ]]
  then
    #
    echo "ERROR: The required file \`$file' is missing." >&2
    error=true
  fi
done
if [[ $error = true ]]
then
  #
  echo >&2
  echo "Program unable to continue - exiting." >&2
  echo >&2
  rm /tmp/$MODE-dns.lock
  exit 2
fi

#
# The necessary files are in place.  Now it it time to
# use the `h2n' utility to build the DNS zone data.
#

echo
echo "Generating zone data for \`domain-1.hp.com':"
#
# IMPORTANT: Copy the active zone files from the `named' directory
#	     into the current directory in which the new zone files
#	     are being built.  This ensures that the correct serial
#	     number sequence will be followed even if one or more
#	     zone files had their serial numbers manually incremented
#	     during a direct edit of data in the active `named' directory.
#
copy_zone_files in options.domain-1 forward_zone_true
$H2N_PROGRAM -f options.domain-1 2> /tmp/h2n.stderr_$$
if (($? != 0))
then
  #
  # The `h2n' program terminated abnormally.
  #
  notice="ERROR"
  ws=""
else
  domain_1_passed=true
  notice="WARNING"	# Just in case there are non-fatal messages to display.
  ws="  "
fi
if [[ -s /tmp/h2n.stderr_$$ ]]
then
  #
  # Errors and/or warnings were generated by the `h2n' script.
  # These will be reported and the script will continue working.
  # It would be overkill to halt the script at this point even
  # if `h2n' terminated abnormally since the `domain-2.hp.com'
  # zone has yet to be processed.  Besides, the name server can
  # continue to work with the existing zone data for `domain-1'
  # until the problem(s) can be fixed.
  #
  cat <<-EOM >&2

	$notice: The \`h2n' script generated the following message(s)
	       ${ws}while processing the \`domain-1.hp.com' DNS data:

	EOM
  cat /tmp/h2n.stderr_$$ >&2
  if [[ $domain_1_passed = false ]]
  then
    echo >&2
    echo "Until the problem is corrected, no new data for this zone" >&2
    echo "will be used by the name servers." >&2
    echo >&2
  else
    echo >&2
    echo "Please make the necessary corrections before the next" >&2
    echo "run of the \`$program_name' program." >&2
    echo >&2
  fi
fi


echo
echo "Generating zone data for \`domain-2.hp.com':"
#
# IMPORTANT: Copy the active zone files from the `named' directory
#	     into the current directory in which the new zone files
#	     are being built.  This ensures that the correct serial
#	     number sequence will be followed even if one or more
#	     zone files had their serial numbers manually incremented
#	     during a direct edit of data in the active `named' directory.
#
copy_zone_files in options.domain-2 forward_zone_true
$H2N_PROGRAM -f options.domain-2 2> /tmp/h2n.stderr_$$
if (($? != 0))
then
  #
  # The `h2n' program terminated abnormally.
  #
  notice="ERROR"
  ws=""
else
  domain_2_passed=true
  notice="WARNING"	# Just in case there are non-fatal messages to display.
  ws="  "
fi
if [[ -s /tmp/h2n.stderr_$$ ]]
then
  #
  # Errors and/or warnings were generated by the `h2n' script.
  # These will be reported and the script will continue working.
  # The script should not be halted at this point even if `h2n'
  # terminated abnormally since the name server still might have to
  # be reloaded if the processing of the `domain-1.hp.com'
  # zone which was done previously was successful.
  #
  cat <<-EOM >&2

	$notice: The \`h2n' script generated the following message(s)
	       ${ws}while processing the \`domain-2.hp.com' DNS data:

	EOM
  cat /tmp/h2n.stderr_$$ >&2
  if [[ $domain_2_passed = false ]]
  then
    echo >&2
    echo "Until the problem is corrected, no new data for this zone" >&2
    echo "will be used by the name servers." >&2
    echo >&2
  else
    echo >&2
    echo "Please make the necessary corrections before the next" >&2
    echo "run of the \`$program_name' program." >&2
    echo >&2
  fi
fi


if [[ ! ( $test_mode = true && $skip_file_copy = true ) ]]
then
  if [[ $domain_1_passed = true || $domain_2_passed = true ]]
  then
    #
    # Copy the updated forward- and reverse-mapping zone files to the
    # operational `named' directory.
    #
    echo
    if [[ $verbose = true ]]
    then
      if [[ $check_mode = true ]]
      then
	echo "The following zone files have updates pending:"
      else
	echo "Copying the following updated zone files to \`$NAMED_DIR/':"
      fi
    else
      if [[ $check_mode = true ]]
      then
	printf "Determining the zone files which have updates pending..."
      else
	printf "Copying updated zone files to \`%s/'..." $NAMED_DIR
      fi
    fi
    #
    # The `copy_zone_files' function will Do The Right Thing depending
    # on the mode in which this script is operating.
    #
    # NOTE: It is unnecessary to copy the `spcl.*' files into the
    #       `named' directory because the `h2n' utility creates
    #       an `$INCLUDE' directive with the absolute path name to
    #       the special files in the current working directory.
    #
    if [[ $domain_1_passed = true ]]
    then
      copy_zone_files out options.domain-1 forward_zone_true
    fi
    if [[ $domain_2_passed = true ]]
    then
      copy_zone_files out options.domain-2 forward_zone_true
    fi
    if ((updated_zones == 0))
    then
      notice="no updates"
    elif ((updated_zones == 1))
    then
      notice="1 update"
    else
      notice="$updated_zones updates"
    fi
    if [[ $check_mode = true ]]
    then
      if ((updated_zones == 1))
      then
	verb="is"
      else
	verb="are"
      fi
      if [[ $verbose = false ]]
      then
	echo
      fi
      echo "  ($notice $verb pending)"
    else
      action="copied"
      if ((updated_zones == 1))
      then
	verb="was"
      else
	verb="were"
	if ((updated_zones == 0))
	then
	  action="necessary"
	fi
      fi
      if [[ $verbose = false ]]
      then
	echo
      fi
      echo "  ($notice $verb $action)"
    fi
    if [[ $check_mode = false && $test_mode = false ]]
    then
      reload_named=true
    fi
  fi
fi

# NOTE: The following section for controlling `named' and
#       inspecting the syslog messages that result is
#       applicable to BIND 8 only!
#

if [[ $reload_named = true ]]
then
  #
  # Check the current state of the name server daemon.
  #
  named_status=$($NDC status 2>&1)
  if [[ $named_status != *"server is up and running"* ]]
  then
    #
    # This point should never be reached since the master name server
    # should always be running.  Make sure the name server gets started.
    #
    ((updated_zones = 1))
  fi
  if ((updated_zones == 0))
  then
    echo
    echo "DNS data is unchanged - no name server reload is necessary."
  else
    #
    # Start/Reload the name server daemon.
    #
    if [[ $named_status = *"server is up and running"* ]]
    then
      #
      # Always prefer a "reload" to a "restart" of a running name server.
      # The advantages are:
      #
      #   1. The cache is not flushed.
      #   2. NOTIFY messages are sent only for updated zones.
      #
      printf "\nReloading the name server ... "
      $NDC reload 2>&1
    else
      printf "\nStarting the name server ... "
      if [[ $USING_BIND9 = false ]]
      then
	$NDC start 2>&1
      else
	$START_BIND9
      fi
    fi
    if [[ $USING_BIND9 = false ]]
    then
      #
      # All good hostmasters check the log file before assuming that
      # everything is fine.
      #
      echo
      echo "IMPORTANT!  Please check the following \`$LOGFILE' output"
      echo "            before assuming that the name server has good data."
      echo

      #
      # If any zone file contained errors, they would be logged between the
      # messages that `named' is either "starting" or "reloading" and that
      # it is "Ready to answer queries".
      # The following section will attempt to extract the `named' log entries
      # between these two messages.
      #
      # Due to the peculiarities of the csplit(1) command that will be called
        # later, we must first use the fold(1) command to break up any lines in
      # the syslog file that are longer than 254 characters.  csplit(1) also
      # misbehaves when dealing with data piped into its standard input.
      # That is why fold(1) does not pipe its output directly into csplit(1).
      #
      SIGNAL="(starting.|reloading nameserver)"
      fold -b -254 $SYSLOG > /tmp/folded_log_$$
      ((start_line = $(grep -En " named\[[0-9]*\]: $SIGNAL" /tmp/folded_log_$$ \
		       | tail -1 | sed -e 's/:.*//') - 1))
      ready=false
      until [[ $ready = true ]]
      do
	csplit -s -f /tmp/syslog_part /tmp/folded_log_$$ "%.%+$start_line" \
	       '/Ready to answer queries./+1' 2> /tmp/csplit_error_$$
	if [[ -s /tmp/csplit_error_$$ ]]
	then
	  #
	  # Make sure that the error returned by csplit(1)
	  # is what we think it is.
	  #
	  csplit_error="$(< /tmp/csplit_error_$$)"
	  if [[ $csplit_error = "/Ready to answer queries./+1 - out of range" ]]
	  then
	    #
	    # The name server is not yet ready to answer DNS queries.
	    # Wait a bit while `named' processes the new zone data.
	    #
	    sleep 10
	    #
	    # Fold a fresh copy of the syslog file.
	    #
	    fold -b -254 $SYSLOG > /tmp/folded_log_$$
	  else
	    #
	    # csplit(1) returned an unexpected error.  Report the situation,
	    # clean up our temporary files, and exit the script.
	    #
	    cat <<-EOM >&2
		ERROR: The csplit(1) command returned the following message:

		EOM
	    cat /tmp/csplit_error_$$ >&2
	    cat <<-EOM >&2

		You must inspect \`$SYSLOG' manually
		to make sure that \`named' encountered no errors with the
		new zone files.

		EOM
	    rm /tmp/$MODE-dns.lock /tmp/folded_log_$$ /tmp/csplit_error_$$
	    exit 2
	  fi
	else
	  ready=true
	  rm /tmp/csplit_error_$$
	fi
      done

      grep ' named\[[0-9]*\]: ' /tmp/syslog_part00 | \
	grep -Ev -e '(USAGE|[NX]STATS|listening on|Forwarding.*address)' \
		 -e '(zone.*loaded|suppressing duplicate|NOTIFY|query from)' \
		 -e 'unrelated additional'

      rm /tmp/folded_log_$$ /tmp/syslog_part[0-9][0-9]
    fi
  fi
fi

if [[ ! ( $test_mode = true && $skip_file_copy = true ) ]]
then
  # Archive the data files to make auditing and error recovery
  # more convenient should it become necessary to do so.
  #
  echo
  if [[ $verbose = true ]]
  then
    if [[ $check_mode = true ]]
    then
      #
      # NOTE: Because files are not actually archived in check
      #       mode, filenames may be displayed more than once
      #       if they appear directly in a "*_FILES" variable
      #       and/or indirectly via an "$INCLUDE" directive.
      #
      echo "The following data files are subject to archival:"
    else
      echo "Archiving the following hosts and \`h2n' data files:"
    fi
  else
    if [[ $check_mode = true ]]
    then
      printf "Determining the data files which are subject to archival..."
    else
      printf "Archiving the hosts and \`h2n' data files..."
    fi
  fi
  #
  # The `compare_data' function will Do The Right Thing depending
  # on the mode in which this script is operating.
  #
  for file in $DOMAIN_1_FILES $DOMAIN_2_FILES
  do
    if [[ $file = db.* ]]
    then
      checkSOA_flag=true
    else
      checkSOA_flag=false
    fi
    compare_data $file archive_true $checkSOA_flag
    if [[ $file = $OPTION_FILE_PATTERN ]]
    then
      #
      # Archive the accompanying `spcl.network' files.
      #
      set_default_network_size /24
      while read -r option_line
      do
	if [[ $option_line = *(" "|"	")-d+(" "|"	")* ]]
	then
	  parse_d_option $option_line
	elif [[ $option_line = *(" "|"	")-N+(" "|"	")* ]]
	then
	  set_default_network_size $option_line
	elif [[ $option_line = *(" "|"	")-n+(" "|"	")* ]]
	then
	  parse_n_option $option_line
	  ((i = 1))
	  while ((i <= num_zones))
	  do
	    spcl_file="spcl.$base_net$dot$last_octet"
	    if [[ -f $spcl_file ]]
	    then
	      compare_data $spcl_file archive_true checkSOA_false
	    elif [[ -s $ARCHIVE_DIR/${spcl_file}_01 ]]
	    then
	      #
	      # If the `spcl.network' file does not exist and yet a non-empty
	      # `spcl.network_01' archive version does exist, this means that
	      # the `spcl.network' file has been removed since the last run
	      # of this program.
	      # It is now very important that the last non-empty version in
	      # the archive directory, `spcl.network_01', get renamed to the
	      # `_02' version and that an empty placeholder file become the
	      # `_01' version.  By doing this, we make sure that only the
	      # currently active `spcl.network' files get restored from the
	      # archive in case that becomes necessary.
	      #
	      touch $spcl_file
	      compare_data $spcl_file archive_true checkSOA_false
	      rm $spcl_file
	    fi
	    if ((num_zones > 1))
	    then
	      ((last_octet += 1))
	    fi
	    ((i += 1))
	  done
	fi
      done < $file
    fi
  done
  if ((archived_files == 0))
  then
    notice="no archivals"
  elif ((archived_files == 1))
  then
    notice="1 archival"
  else
    notice="$archived_files archivals"
  fi
  if [[ $check_mode = true ]]
  then
    if ((archived_files == 1))
    then
      verb="is"
    else
      verb="are"
    fi
    if [[ $verbose = false ]]
    then
      echo
    fi
    echo "  ($notice $verb pending)"
  else
    action="performed"
    if ((archived_files == 1))
    then
      verb="was"
    else
      verb="were"
      if ((archived_files == 0))
      then
	action="necessary"
      fi
    fi
    if [[ $verbose = false ]]
    then
      echo
    fi
    echo "  ($notice $verb $action)"
  fi
fi

#
# Finally, remove the lock file that was built at the start of this script.
#
rm /tmp/$MODE-dns.lock

echo
echo "----- \`$program_name'$mode_comment finished at $(date)."
echo

exit 0
