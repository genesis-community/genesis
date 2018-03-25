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
__DATA__
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
  for __feature in GENESIS_REQUESTED_FEATURES; do
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
  for have in genesis_REQUESTED_FEATURES; do
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
  for __have in genesis_REQUESTED_FEATURES; do
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
    echo >&2 "genesis_KIT_NAME/genesis_KIT_VERSION does not understand the following feature flags:"
    for __bad in $(invalid_features "$@"); do
      echo >&2 " - $__bad"
    done
    exit 1
  fi
}
export -f validate_features





describe() {
	genesis ui-describe ""  "$@"
}
export -f describe

prompt_for() {
	local __var="$1" __type="$2"; shift 2;
	if [[ "$__type" =~ ^secret- ]] ; then
		export GENESIS_TARGET_VAULT="$ENV{GENESIS_TARGET_VAULT}"
		genesis ui-prompt-for "$__type" "$__var" "$@"
		local __rc="$?"
		[[ $__rc -ne 0 ]] && echo "Error encountered - cannot continue" && exit $__rc
	else
		local __tmpfile
		__tmpfile=$(mktemp)
		[[ $? -ne 0 ]] && echo >&2 "Failed to create tmpdir: $__tmpfile" && exit 2
		genesis ui-prompt-for "$__type" "$__tmpfile" "$@"
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
			eval "while IFS= read -r -d '' \\"${__var}[__i++]\\"; do :; done < \\"$__tmpfile\\""
			eval "$__var=(\\"\\${${__var}[@]:1}\\")"
		else
			eval "$__var=\\$(<\\"$__tmpfile\\")"
		fi
		rm -f "$__tmpfile"
	fi
	return 0
}
export -f prompt_for
