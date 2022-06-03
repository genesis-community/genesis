package Genesis::Helpers;

my $SCRIPT;

sub write {
	my ($class, $file) = @_;

	open my $fh, ">", $file
		or die "Could not open $file for writing the helpers script: $!\n";

	if (!$SCRIPT) {
		$SCRIPT = do { local $/, <DATA> };
		close(DATA);
	}

	print $fh $SCRIPT;
	close $fh;
}

1;

=head1 NAME

Genesis::Helpers

=head1 DESCRIPTION

This module wraps up the bash hooks helper that defines various functions
designed to make life easier on Kit authors.  It also includes a method for
writing the helper to an extracted kit workspace, but primarily we're using
the separate module to abuse Perl's awesome __DATA__ facility.

=head1 FUNCTIONS

=head2 write($path)

Writes the hooks helper to the given C<$path>.  Can be called more than
once, without issue.

=cut

__DATA__

if [[ "${GENESIS_TRACE}" == "y" ]] ; then
  echo >&2 "TRACE> Helper script environment variables:"
  export >&2
fi

genesis() {
  [[ -z "${GENESIS_CALLBACK_BIN}" ]] \
    && echo >&2 "Genesis command not specified - this is a bug in Genesis, or you are running $0 outside of Genesis" \
    && exit 2
  command "${GENESIS_CALLBACK_BIN}" -C "$GENESIS_ROOT" "$@"
  return $?
}
export -f genesis

describe() {
  /usr/bin/env perl -I$GENESIS_LIB -MGenesis -e 'binmode STDOUT, ":encoding(UTF-8)"; explain("%s",$_) for @ARGV' "$@"
}
export -f describe

humanize_path() {
  /usr/bin/env perl -I$GENESIS_LIB -MGenesis -e 'binmode STDOUT, ":encoding(UTF-8)"; print humanize_path("$ARGV[0]")' "$1"
}
export -f humanize_path

__bail() {
  local rc=1
  [[ "$1" == "--rc" ]] && rc="$2" && shift 2
  describe "$@" >&2
  exit $rc
}
export -f __bail

# Make __bail available as bail because internal functions shouldn't be used by non-helpers
bailfunc="$(declare -f "__bail")"
eval "${bailfunc/__bail/bail}"
export -f bail

# Protect safe calls if safe target is not set correctly
if [[ -z "$SAFE_TARGET" || "$SAFE_TARGET" != "$GENESIS_TARGET_VAULT" ]] ; then
  safe() {
    __bail "Safe target not associated with Genesis Vault -- this is a bug in Genesis, or you are running $0 outside of Genesis"
  }
  export -f safe
fi

###
###   Exodus Data Exfiltration Functions
###

# exodus - lookup exodus data about this or other deployments / envs.
#
# USAGE:  exodus some-key
#         exodus other-env/type their-key
#
# Examples:
#
#    # what version was I last deployed with?
#    exodus kit_version
#
#    # what is the TSA URL of my Concourse?
#    exodus my-proto/concourse tsa_url
#
#    # what is the CF URL of my local instance?
#    exodus $GENESIS_ENVIRONMENT/cf api_url
#
exodus() {
  # movement of the people
  local __env __key
  __env="$GENESIS_ENVIRONMENT/$GENESIS_TYPE"
  __key=${1:?exodus() must provide at least an exodus key}
  if [[ -n ${2:-} ]]; then
    __key=$2
    __env=$1
  fi
  if [[ "$__key" == "--all" ]] ; then
    if safe exists "${GENESIS_EXODUS_MOUNT}${__env}"; then
      safe get ${GENESIS_EXODUS_MOUNT}${__env} | spruce json | jq -r .
    fi
  else
    if safe exists "${GENESIS_EXODUS_MOUNT}${__env}:${__key}"; then
      safe get "${GENESIS_EXODUS_MOUNT}${__env}:${__key}"
    fi
  fi
}
export -f exodus

# have_exodus_data_for env/type - return true if exodus data exists
have_exodus_data_for() {
  local __env=${1:?have_exodus_data_for() must provide an environment/type}
  safe exists "${GENESIS_EXODUS_MOUNT}${__env}"
  return $?
}
export -f have_exodus_data_for

have_exodus_data() {
  have_exodus_data_for "${GENESIS_ENVIRONMENT}/${GENESIS_TYPE}"
  return $?
}
export -f have_exodus_data

###
### new_enough - Check semantic versions
###
### USAGE: new_enough $have $minimum
###
new_enough() {
  check_errors="$(printf %s\\n "$-" | grep 'e' 2>/dev/null)";
  set +e
  local __have=${1:?new_enough() requires an actual version as the first argument}
  local __min=${2:?new_enough() requires an actual version as the second argument}
  genesis ui-semver "$__have" ge "$__min"
  rc=$?
  [[ -z "$check_errors" ]] || set -e
  return $rc # stop -e in the calling scope from failing
}
export -f new_enough

###
###   Environment File Inspection Functions
###

# lookup key [default]
#
# Looks up the key in the environment files, taken as
# an skip-eval'd spruce merge.
#
# If the key is not found, $default is returned as a
# value.  If $default is not set, the empty string will
# be used instead.
#
lookup() {
  genesis lookup "$GENESIS_ENVIRONMENT" "$@"
}
export -f lookup

deployed() {
  lookup --exodus dated --defined
  return $?
}
export -f deployed

typeof() {
  local __key=${1:?typeof() - must specify a key to look up}
  local __val
  __val="$(genesis  lookup "$__key" "$GENESIS_ENVIRONMENT" "" |  sed -e 's/\(.\).*/\1/')"
  if [[ $__val == "{" ]]; then
    echo "map"
  elif [[ $__val == "[" ]]; then
    echo "list"
  elif [[ $__val == "" ]]; then
    echo ""
  else
    echo "scalar"
  fi
}
export -f typeof

###
###   BOSH Inspection Functions
###

bosh() {
  if [[ -f ${GENESIS_ROOT}/${GENESIS_ENVIRONMENT}.yml ]] ; then
    command "${GENESIS_CALLBACK_BIN}" "${GENESIS_ROOT}/${GENESIS_ENVIRONMENT}.yml" bosh "$@"
    rc="$?"
    [[ "$rc" == "0" ]] && export GENESIS_BOSH_VERIFIED="$BOSH_ALIAS"
    return "$rc"
  fi

  # Do things the old way if there is no environment yaml for any reason...
  [[ -z "${GENESIS_BOSH_COMMAND:-}" ]] && \
    __bail "" "#R{[ERROR]} BOSH CLI command not specified - this is a bug in Genesis, or you are running $0 outside of Genesis"

  if [[ -z "${BOSH_ENVIRONMENT:-}" || -z "${BOSH_CA_CERT:-}" ]] ; then
    # Try to get the env vars...
    if [[ -n "${BOSH_ALIAS}" ]] ; then
      perl_script="$(cat <<'      EOF'
      my $bosh=(
        Genesis::BOSH::Director->from_exodus($ENV{BOSH_ALIAS}) ||
        Genesis::BOSH::Director->from_alias($ENV{BOSH_ALIAS})
      );
      print "echo 'Could not connect to $ENV{BOSH_ALIAS}'\n" unless $bosh;
      my %vars = $bosh->environment_variables;
      for (keys %vars) {
        print "export $_=\"$val{$_}\"\n";
      }
      EOF
      )"
      eval "$(/usr/bin/env perl -I$GENESIS_LIB -MGenesis::BOSH::Director -e "$perl_script")"
    fi
    [[ -z "${BOSH_ENVIRONMENT:-}" || -z "${BOSH_CA_CERT:-}" ]] && \
      __bail "" "#R{[ERROR]} Environment not found for BOSH Director -- please ensure you've configured your BOSH alias used by this environment"
  fi

  if [[ -z "${GENESIS_BOSH_VERIFIED:-}" || "$GENESIS_BOSH_VERIFIED" != "${BOSH_ALIAS:-}" ]] ; then
    # Genesis has not yet validate the BOSH director's availability, so we need to
    if /usr/bin/env perl -I$GENESIS_LIB -MGenesis::BOSH::Director -e 'exit(Genesis::BOSH::Director->from_environment()->connect_and_validate()?0:1)' ; then
      GENESIS_BOSH_VERIFIED="$BOSH_ALIAS"
    else
      __bail "" "#R{[ERROR]} Could not connect to BOSH director '#M{$BOSH_ALIAS}' (#M{$BOSH_ENVIRONMENT})"
    fi
  fi

  [[ -n "${GENESIS_SHOW_BOSH_CMD:-}" ]] && \
    describe  >&2 "#M{BOSH>} $GENESIS_BOSH_COMMAND $*"
  command ${GENESIS_BOSH_COMMAND} "$@"
  return $?
}
export -f bosh

bosh_cpi() {
  local __have_env
  if [[ -n "${GENESIS_TESTING_BOSH_CPI:-}" ]] ; then
    echo "$GENESIS_TESTING_BOSH_CPI"
    return 0
  fi
  __have_env="$(bosh env --json | jq -r '.Tables[0].Rows[0].cpi')"
  [[ "$?" != "0" ]] && \
    __bail "Cannot determine CPI from BOSH director - failed to communicate with BOSH director:" \
           "${__have_env}"
  [[ -z "${__have_env}" ]] && \
    __bail "Cannot determine CPI from BOSH director - no response from BOSH director"

  echo "${__have_env%_cpi}"
  return 0
}
export -f bosh_cpi

use_create_env() {
	if ! new_enough "$GENESIS_MIN_VERSION" 2.8.0 ; then
		return 1 # bosh kit is the only pre-v2.8.0 use-create-env kit, and it uses a different mechanism
	fi
	[[ "${GENESIS_USE_CREATE_ENV:-0}" == "1" ]]
}
export -f use_create_env

###
###   Cloud-Config Inspection Functions
###
export __cloud_config_ok="yes"

# Support function for cloud_config_needs static_ips
__ip2dec() {
  local __acc=0 IFS='.' __b __ip="$1"
  # this doesn't work if __ip[@] is quoted (using IFS to split on .) - shellcheck warns that it's not quoted
  # https://github.com/koalaman/shellcheck/wiki/SC2068
  # shellcheck disable=SC2068
  for __b in ${__ip[@]} ; do
    (( __acc = (__acc << 8) + __b ))
  done
  unset IFS
  echo $__acc
}
export -f __ip2dec

declare -a __checked_cloud_config
__checked_cloud_config=( '' )
__in_cloudconfig_check=''
cloud_config_needs() {
  local __type=${1:?cloud_config_needs() - must specify a type}; shift
  local __name
  local __unbound_check=0
  if [[ $- =~ 'u' ]] ; then
    set +u
    __unbound_check=1
  fi

  if [[ -z "$__in_cloudconfig_check" ]] ; then
    describe "  #C{[Checking cloud config]}"
    __in_cloudconfig_check=1
  fi

  # Special check for static_ips
  if [[ "${__type}" == "static_ips" ]] ; then
    local __network=${1:?cloud_config_needs(static_ips) - must supply network name}; shift
    local __count=${1:?cloud_config_needs(static_ips) - must supply static_ip count} ; shift

    local __ips __sum=0 __f __x __l
    __ips=$(spruce json "$GENESIS_CLOUD_CONFIG" | \
      jq -r --arg network "$__network" '.networks[]| select(.name == $network) | .subnets[] | .static[]')

    while read -r __range ; do
      [[ -z "$__range" ]] && continue # blank line
      if echo "$__range" | grep -q '^\s*[\.0-9]*\(\s*-\s*[0-9\.]*\)\{0,1\}\s*$' ; then
        read -r __f __x __l < <(
          echo "$__range" | \
          sed 's/^[[:space:]]*\([^-[:space:]]*\)[[:space:]]*\(\(-\)[[:space:]]*\(.*\) \)\{0,1\}/\1 \3 \4/' | \
          sed -e 's/[[:space:]]$//' )
        if [[ -z "$__x" && -z "$__l" ]] ; then
          (( __sum++ )) # Single ip
        elif [[ "$__x" == '-' ]] ; then
          (( __sum += $(__ip2dec "$__l") - $(__ip2dec "$__f") + 1 )) # Range
        fi
        __cloud_config_error_messages+=( "    [#G@{+}] network '$__network' has valid static ips #G{('$__range')} ")
      else
        __cloud_config_error_messages+=( "    [#R@{-}] network '$__network' has valid static ips #R{(parse error on '$__range')} ")
        __cloud_config_ok=no
        break
      fi
    done < <(echo "${__ips}")
    if [[ "$__sum" -lt "$__count" ]] ; then
      __cloud_config_error_messages+=( "    [#R@{-}] network '$__network' has sufficient static ips #R{(found $__sum, need $__count)} ")
      __cloud_config_ok=no
    else
      __cloud_config_error_messages+=( "    [#G{+}] network '$__network' has sufficient static ips #G{(found $__sum, need $__count)} ")
    fi
    if [[ -n "$__in_cloudconfig_check" ]] ; then
      describe "${__cloud_config_error_messages[@]}"
      __cloud_config_error_messages=()
    fi
  fi

  # Generic pattern
  case "${__type}" in
  vm_type|vm_types)            __type=vm_types;      __name=vm_type      ;;
  vm_extension|vm_extensions)  __type=vm_extensions; __name=vm_extension ;;
  network|networks)            __type=networks;      __name=network      ;;
  disk_type|disk_types)        __type=disk_types;    __name=disk_type    ;;
  az|azs)                      __type=azs;           __name=az           ;;
  *) __bail --rc 77
            "cloud_config_needs(): invalid cloud-config object type '$__type'; must be one of" \
            "                      'vm_type', 'vm_extension', 'disk_type', or 'az'" ;;
  esac

  local __want __have __token
  for __want in "$@"; do
    __token="$__name:$__want"
    if ! (IFS=$'\n'; echo "${__checked_cloud_config[*]}") | grep '^'$__token'$' >/dev/null 2>&1 ; then
      __checked_cloud_config+=("$__token")
      __have=$(spruce json "$GENESIS_CLOUD_CONFIG" | \
        jq -r "if ((.${__type}//[])[] | select(.name == \"$__want\")) then 1 else 0 end")
      if [[ -z "$__have" ]]; then
        __cloud_config_ok=no
        __cloud_config_error_messages+=( "    [#R@{-}] $__name '#Y{$__want}' exists" )
      else
        __cloud_config_error_messages+=( "    [#G@{+}] $__name '#Y{$__want}' exists" )
      fi
    fi
  done
  if [[ -n "$__in_cloudconfig_check" ]] ; then
    describe "${__cloud_config_error_messages[@]}"
    __cloud_config_error_messages=( )
  fi

  [[ "$__unbound_check" = '1' ]] && set -u
}
export -f cloud_config_needs

check_cloud_config() {
  # check_cloud_config - outputs errors found by cloud_config_needs.  Returns 1
  # if any errors were found.
  # Usage:
  #   check_cloud_config || exit 1  # exit if errors found
  #   check_cloud_config && describe "  cloud config [#G{OK}] # report ok if no errors
  if [[ -z "$__in_cloudconfig_check" ]] ;then
    describe "  #C{[Checking cloud config]}"
    describe "${__cloud_config_error_messages[@]}"
  fi
  if [[ ${__cloud_config_ok} != "yes" ]]; then
    return 1
  fi
}
export -f check_cloud_config

cloud_config_has() {
  local __type=${1:?cloud_config_has() - must specify a type}
  local __want=${2:?cloud_config_has() - must specify a name}
  local __name
  case "${__type}" in
  vm_type|vm_types)            __type=vm_types;      __name=vm_type      ;;
  vm_extension|vm_extensions)  __type=vm_extensions; __name=vm_extension ;;
  network|networks)            __type=networks;      __name=network      ;;
  disk_type|disk_types)        __type=disk_types;    __name=disk_type    ;;
  az|azs)                      __type=azs;           __name=az           ;;
  *) __bail --rc 77
            "cloud_config_needs(): invalid cloud-config object type '$__type'; must be one of" \
            "                      'vm_type', 'vm_extension', 'disk_type', or 'az'" ;;
  esac

  __have=$(spruce json "$GENESIS_CLOUD_CONFIG" | \
    jq -r "if (.(${__type}//[])[] | select(.name == \"$__want\")) then 1 else 0 end")
  if [[ -n "$__have" ]]; then
    return 0
  else
    return 1
  fi
}
export -f cloud_config_has

export __cc_data=
ccq() {
  [[ -z "${GENESIS_CLOUD_CONFIG+x}" ]] && bail "Cloud config contents not available - cannot continue"
  [[ -z "${__cc_data}" ]] && __cc_data="$(spruce json "$GENESIS_CLOUD_CONFIG")"
  echo "$__cc_data" | jq -r "$@"
}
export -f ccq

export __rc_data=
rcq() {
  [[ -z "${GENESIS_RUNTIME_CONFIG+x}" ]] && bail "Runtime config contents not available - cannot continue"
  [[ -z "${__rc_data}" ]] && __rc_data="$(spruce json "$GENESIS_RUNTIME_CONFIG")"
  echo "$__rc_data" | jq -r "$@"
}
export -f rcq

###
###   Feature Flag Functions
###

# want_feature X
#
# Returns true (0) if the named feature was specified in the
# list of feature flags for the current environment.
#
# Example usage:
#
#    if want_feature uaa-auth; then
#      uaa --something or-other
#    fi
#
want_feature() {
  local __want=${1:?want_feature() -- must specify a feature}
  local __feature
  for __feature in $GENESIS_REQUESTED_FEATURES; do
    [[ "$__want" == "$__feature" ]] && return 0
  done
  return 1
}
export -f want_feature

# invalid_features
#
# Prints a list of requested features that were not listed
# in the (given) list of defined / valid features.
#
# Example:
#
#    for bad in $(invalid_features x y z); then
#      echo "ERROR: $bad is not a valid feature (not one of x, y, or z)"
#    done
#
invalid_features() {
  local __found
  local __valid
  local __have
  declare -a __invalid
  for __have in $GENESIS_REQUESTED_FEATURES; do
    [[ "$__have" =~ ^\+ ]] && continue
    __found='';
    for __valid in "$@"; do
      [[ "$__have" == "$__valid" ]] && __found=1 && break
    done
    [[ -n $__found ]] || __invalid+=("$__have")
  done
  [[ "${#__invalid[@]}" -gt 0 ]] && \
    echo "${__invalid[@]}"
  return 0
}
export -f invalid_features

valid_features() {
  local __have
  local __found
  local __valid
  for __have in $GENESIS_REQUESTED_FEATURES; do
    [[ "$__have" =~ ^\+ ]] && continue
    __found=''
    for __valid in "$@"; do
      [[ "${__have}" = "${__valid}" ]] && __found=1 && break
    done
    [[ -n $__found ]] || return 1
  done
  return 0
}
export -f valid_features

validate_features() {
  local __bad
  if ! valid_features "$@"; then
    __bail "#R{[ERROR]} $GENESIS_KIT_ID does not understand the following feature flags:" \
      "$(for __bad in $(invalid_features "$@"); do echo " - $__bad"; done; echo)"
  fi
}
export -f validate_features

prompt_for() {
  local __var="$1" __type="$2"; shift 2;
  if [[ "$__type" =~ ^secret- ]] ; then
    genesis ui-prompt-for "$__type" "$__var" "$@"
    local __rc="$?"
    [[ $__rc -ne 0 ]] && echo "Error encountered - cannot continue" && exit $__rc
  else
    local __tmpfile
    __tmpfile=$(mktemp);
    [[ $? -ne 0 ]] && echo >&2 "Failed to create tmpfile: $__tmpfile" && exit 2
    genesis ui-prompt-for "$__type" "$__tmpfile" "$@"
    local __rc="$?"
    if [[ $__rc -ne 0 ]] ; then
      # error
      rm -f "$__tmpfile"
      _bail --rc "$__rc" "Error encountered - cannot continue";
    fi
    if [[ $__type =~ ^multi- ]] ; then
      eval "unset $__var; ${__var}=()"
      # __block is escaped in eval, shellcheck thinks its unused
      # https://github.com/koalaman/shellcheck/wiki/SC2034
      # shellcheck disable=SC2034
      while IFS= read -rd '' __block; do
        eval "${__var}+=( \"\$__block\" )"
      done < "$__tmpfile"
    else
      eval "$__var=\$(<\"$__tmpfile\")"
    fi
    rm -f "$__tmpfile"
  fi
  return 0
}
export -f prompt_for

param_entry() {
  local __disabled=""
  local __varname="${1:?param_entry - missing variable name}"
  local     __key="${2:?param_entry - missing key}"
  local     __opt="${3:-}"
  shift 3 || true
  if [[ "$__opt" == "-d" ]] ; then
    __disabled="#"
    __opt="${1:-}" ; shift || true
  fi
  if [[ "$__opt" == "-a" ]] ; then
    if [[ "${#@}" -eq 0 ]] ; then
      eval "$__varname+=\"  $__disabled\$__key: []\\n\""
    else
      eval "$__varname+=\"  $__disabled\$__key:\\n\""
      local __line
      for __line in "$@" ; do
        if [[ "$(echo "$__line" | wc -l)" -gt 1 ]] ; then
          __line="|-"$'\n'"$(echo "$__line" | sed -e "s/^\\(.\\)/  $__disabled  \\1/")"
        fi
        eval "$__varname+=\"  \$__disabled- \$__line\\n\""
      done
    fi
  else
    if [[ -z "$__opt" ]] ; then
      __opt="$(eval "echo \"\$$__key\"")"
    fi
    if [[ "$(echo "$__opt" | wc -l)" -gt 1 ]] ; then
      __opt="|-"$'\n'"$(echo "$__opt" | sed -e "s/^\\(.\\)/  $__disabled  \\1/")"
    fi
    eval "$__varname+=\"  $__disabled\$__key: \$__opt\\n\""
  fi
}
export -f param_entry

param_comment() {
  # Usage: param_comment <var> [-e] [line ...]
  #
  # Adds the lines specified to the contents of the variable passed by
  # reference.  If `-e` is specified, also echos the lines to the users screen
  # so it can be used as a preamble in front of a prompt for a value (see
  # param_entry)

  local __line __echo __varname=$1; shift
  if [[ "$1" == '-e' ]] ; then
    __echo="true"; shift
  fi
  eval "$__varname+=\"\\n\""
  [[ -n $__echo ]] && echo ""
  # __line is escaped in eval, shellcheck thinks its unused
  # https://github.com/koalaman/shellcheck/wiki/SC2034
  # shellcheck disable=SC2034
  for __line in "$@" ; do
    eval "$__varname+=\"  # \$__line\\n\""
    [[ -n $__echo ]] && echo "$__line"
  done
}
export -f param_comment

# Helper to inject new Genesis configuration (v2.6.13+)
genesis_config_block() {
	config_block="$(
	if [[ "${GENESIS_USE_CREATE_ENV:-}" == '1' ]] ; then
		cat <<EOF
  bosh_env:       ((prune))
EOF
	elif [[ "${BOSH_ALIAS:-}" != "${GENESIS_ENVIRONMENT:-}" && -n "${BOSH_ALIAS:-}" ]] ; then
		cat <<EOF
  bosh_env:       $BOSH_ALIAS
EOF
	fi
	if [[ -n "${GENESIS_MIN_VERSION:-}" && $GENESIS_MIN_VERSION != '0.0.0' ]] ; then
		cat <<EOF
  min_version:    $GENESIS_MIN_VERSION
EOF
	fi
	if [[ -n "${GENESIS_SECRETS_SLUG_OVERRIDE:-}" ]] ; then
		cat <<EOF
  secrets_path:   $GENESIS_SECRETS_SLUG
EOF
	fi
	if [[ -n "${GENESIS_SECRETS_MOUNT_OVERRIDE:-}" ]] ; then
		cat <<EOF
  secrets_mount:  $GENESIS_SECRETS_MOUNT
EOF
	fi
	if [[ -n "${GENESIS_EXODUS_MOUNT_OVERRIDE:-}" ]] ; then
		cat <<EOF
  exodus_mount:   $GENESIS_EXODUS_MOUNT
EOF
	fi
	if [[ -n "${GENESIS_CI_MOUNT_OVERRIDE:-}" ]] ; then
		cat <<EOF
  ci_mount:       $GENESIS_CI_MOUNT
EOF
	fi
	if [[ -n "${GENESIS_ROOT_CA_PATH:-}" ]] ; then
		cat <<EOF
  root_ca_path:   $GENESIS_ROOT_CA_PATH
EOF
	fi
	if [[ -n "${GENESIS_CREDHUB_EXODUS_SOURCE_OVERRIDE:-}" ]] ; then
		cat <<EOF
  credhub_env:    $GENESIS_CREDHUB_EXODUS_SOURCE_OVERRIDE
EOF
	fi
	)"
	echo ""
	echo "genesis:"
	padding=""

	if use_create_env || [[ -n $config_block ]] ; then
		padding="           "
	fi
	echo "  env: ${padding}$GENESIS_ENVIRONMENT"

	if use_create_env ; then
		echo "  use_create_env: true"
	fi
	if [[ -n $config_block ]] ; then
		echo "$config_block"
	fi
	echo ""
}
export -f genesis_config_block

offer_environment_editor() {
  local __file __tmpdir __editor __edit_query __editor_cmd
  prompt_for __edit_query boolean \
    "Would you like to edit the '$GENESIS_ENVIRONMENT.yml' environment file?" \
    --inline

  if [[ $__edit_query == 'true' ]] ; then
    local __unbound_check=0
    if [[ $- =~ 'u' ]] ; then
      set +u
      __unbound_check=1
    fi
    __file="$GENESIS_ROOT/$GENESIS_ENVIRONMENT.yml"
    # Shellcheck doesn't know that GENESIS_KIT_VERSION is always supplied.
    # https://github.com/koalaman/shellcheck/wiki/SC2153
    # shellcheck disable=SC2153
    __tmpdir="$(mktemp -d)/$GENESIS_KIT_NAME-$GENESIS_KIT_VERSION"
    mkdir -p "$__tmpdir"
    [[ -n $EDITOR ]] || EDITOR="vim"
    if $GENESIS_CALLBACK_BIN -C $GENESIS_ROOT man "$(basename "$__file")" > "$__tmpdir/manual.md" ; then
      __editor="$(basename $EDITOR)"
      [[ $__editor =~ ^.*vim?$ ]] && \
        __editor_cmd="$EDITOR -O '$__file' '$__tmpdir/manual.md'"
      [[ $__editor == "emacs" ]] && \
        __editor_cmd="$EDITOR -nw '$__file' -f split-window-horizontally '$__tmpdir/manual.md' -f other-window"
    fi
    [[ -n "$__editor_cmd" ]] || __editor_cmd="$EDITOR '$__file'"
    env -i HOME="$HOME" SHELL="$(which bash)" USER="$USER" COLORTERM="$COLORTERM" TERM="$TERM" bash -l -c "$__editor_cmd"
    [[ -f $__tmpdir/manual.md ]] && rm "$__tmpdir/manual.md"
    rmdir "$__tmpdir"
    rmdir "$(dirname "$__tmpdir")"
    [[ "$__unbound_check" = '1' ]] && set -u
  fi
}
export -f offer_environment_editor

move_secrets_to_credhub() {
  local value src="$1" dst="$2"
  value="$(safe get "${GENESIS_SECRETS_BASE}$src")"
  result="$(credhub set -n "/$GENESIS_CREDHUB_ROOT/$dst" -t value -v "$value" 2>&1)"
  if [[ $? -gt 0 ]] ; then
    bail "#R{[ERROR]} Failed to store secret #C{$1} under credhub path #C{$2}:" "$result"
  fi
  result="$(safe rm "${GENESIS_SECRETS_BASE}$src" 2>&1)"
}
export -f move_secrets_to_credhub

version_check() {
  local min_version
  min_version="${1:?"${FUNCNAME[0]} called without specifying minimum version"}"
  if ! [[ "$GENESIS_VERSION" =~ -dev$ ]] && ! new_enough "$GENESIS_VERSION" "$min_version" ; then
    describe >&2 "" "#R{[ERROR]} Genesis v$min_version is required by $GENESIS_KIT_HOOK.  Please upgrade before continuing" ""
    return 1
  fi
  return 0
}
export -f version_check
