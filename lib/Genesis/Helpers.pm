package Genesis::Helpers;

my $SCRIPT;

sub write {
	my ($class, $file) = @_;

	open my $fh, ">", $file
		or die "Could not open $file for writing the helpers script: $!\n";

	if (!$SCRIPT) {
		$SCRIPT = do { local $/, <DATA> };
		close($data);
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
  if safe exists "secret/genesis/${__env}:${__key}"; then
    safe get "secret/genesis/${__env}:${__key}"
  fi
}
export -f exodus

# have_exodus_data_for env/type - return true if exodus data exists
#
have_exodus_data_for() {
  local __env=${1:?have_exodus_data_for() must provide an environment/type}
  safe exists "secret/genesis/${__env}"
  return $?
}
export -f have_exodus_data_for

have_exodus_data() {
  have_exodus_data_for "$GENESIS_ENVIRONMENT/$GENESIS_TYPE"
  return $?
}
export -f have_exodus_data

###
### new_enough - Check semantic versions
###
### USAGE: new_enough $have $minimum
###
new_enough() {
  local __have=${1:?new_enough() requires an actual version as the first argument}
  local __min=${2:?new_enough() requires an actual version as the second argument}
  $GENESIS_CALLBACK_BIN ui-semver "$__have" ge "$__min"
  return $?
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
  local __key=${1:?lookup() - must specify a key to look up}
  local __default=${2:-}

  $GENESIS_CALLBACK_BIN -C "$GENESIS_ROOT" lookup "$__key" $GENESIS_ENVIRONMENT "$__default"
}
export -f lookup


typeof() {
  local __key=${1:?typeof() - must specify a key to look up}
  local __val=$($GENESIS_CALLBACK_BIN -C "$GENESIS_ROOT" lookup "$__key" $GENESIS_ENVIRONMENT "" |  sed -e 's/\(.\).*/\1/')
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

bosh_cpi() {
  if [[ -n "${GENESIS_ENV_BOSH_TARGET:-}" ]]; then
    bosh -e "$GENESIS_ENV_BOSH_TARGET" env --json | jq -r '.Tables[0].Rows[0].cpi'
  fi
}
export -f bosh_cpi

###
###   Cloud-Config Inspection Functions
###
export __cloud_config_ok=""

cloud_config_needs() {
  local __type=${1:?cloud_config_needs() - must specify a type}; shift
  local __name

  if [[ -z "$__cloud_config_ok" ]] ; then
    __cloud_config_ok=yes
    declare -a __cloud_config_error_messages;
  fi
  case "${__type}" in
  vm_type|vm_types)            __type=vm_types;      __name=vm_type      ;;
  vm_extension|vm_extensions)  __type=vm_extensions; __name=vm_extension ;;
  network|networks)            __type=networks;      __name=network      ;;
  disk_type|disk_types)        __type=disk_types;    __name=disk_type    ;;
  az|azs)                      __type=azs;           __name=az           ;;
  *) echo >&2 "cloud_config_needs(): invalid cloud-config object type '$__type'; must be one of"
     echo >&2 "                      'vm_type', 'vm_extension', 'disk_type', or 'az'"
     exit 77 ;;
  esac

  local __want __have
  for __want in "$@"; do
    __have=$(spruce json "$GENESIS_CLOUD_CONFIG" | \
      jq -r "if (.${__type}[] | select(.name == \"$__want\")) then 1 else 0 end")
    if [[ -z "$__have" ]]; then
      __cloud_config_ok=no
      __cloud_config_error_messages+=( "no #Y{$__name} named '#Y{$__want}' found, which is required" )
    fi
  done
}
export -f cloud_config_needs

check_cloud_config() {
  if [[ ${__cloud_config_ok} != "yes" ]]; then
    describe "#R{Errors were encountered} in your cloud-config:"
    local __e
    for __e in "${__cloud_config_error_messages[@]}"; do
      describe " - ${__e}"
    done
    echo
    exit 1
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
  *) echo >&2 "cloud_config_has(): invalid cloud-config object type '$__type'; must be one of"
     echo >&2 "                    'vm_type', 'vm_extension', 'disk_type', or 'az'"
     exit 77 ;;
  esac

  __have=$(spruce json "$GENESIS_CLOUD_CONFIG" | \
    jq -r "if (.${__type}[] | select(.name == \"$__want\")) then 1 else 0 end")
  if [[ -n "$__have" ]]; then
    return 0
  else
    return 1
  fi
}
export -f cloud_config_has

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
  for have in $GENESIS_REQUESTED_FEATURES; do
    __found='';
    for __valid in "$@"; do
      [[ "$__have" == "$__valid" ]] && __found=1 && break
    done
    [[ -n $__found ]] || __invalid+=($__have)
  done
  echo "${__invalid[@]}"
  return 0
}
export -f invalid_features

valid_features() {
  local __have
  local __found
  local __valid
  for __have in $GENESIS_REQUESTED_FEATURES; do
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
    echo >&2 "$GENESIS_KIT_NAME/$GENESIS_KIT_VERSION does not understand the following feature flags:"
    for __bad in $(invalid_features "$@"); do
      echo >&2 " - $__bad"
    done
    exit 1
  fi
}
export -f validate_features





describe() {
	$GENESIS_CALLBACK_BIN ui-describe "$@"
}
export -f describe

prompt_for() {
	local __var="$1" __type="$2"; shift 2;
	if [[ "$__type" =~ ^secret- ]] ; then
		$GENESIS_CALLBACK_BIN ui-prompt-for "$__type" "$__var" "$@"
		local __rc="$?"
		[[ $__rc -ne 0 ]] && echo "Error encountered - cannot continue" && exit $__rc
	else
		local __tmpfile
		__tmpfile=$(mktemp)
		[[ $? -ne 0 ]] && echo >&2 "Failed to create tmpdir: $__tmpfile" && exit 2
		$GENESIS_CALLBACK_BIN ui-prompt-for "$__type" "$__tmpfile" "$@"
		local __rc="$?"
		if [[ $__rc -ne 0 ]] ; then
			# error
			echo "Error encountered - cannot continue";
			rm -f "$__tmpfile"
			exit $__rc
		fi
		if [[ $__type =~ ^multi- ]] ; then
			local __i
			eval "unset $__var"
			eval "while IFS= read -r -d '' \"${__var}[__i++]\"; do :; done < \"$__tmpfile\""
			eval "$__var=(\"\${${__var}[@]:1}\")"
		else
			eval "$__var=\$(<\"$__tmpfile\")"
		fi
		rm -f "$__tmpfile"
	fi
	return 0
}
export -f prompt_for
