package Genesis::Env::SecretsStore;
use strict;
use warnings;

### Class Methods {{{

# new -  abstract builder for creating a secrets store for an environment {{{
sub new {
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($_[0]), 'new');
	# Input expected:
	#   environment: environment object
	#   options:     key-value pairings to configure secrets store
	#
	# Output expected:
	#   New derived SecretsStore object.
}

# }}}
# provide - factory method for providing a Secrets::Store object of the correct class {{{
sub provide {
	my ($class, $env, $service, %options) = @_;
	if (ref($service) =~ /^Service::Vault::(Remote|Local)$/) {
		require Genesis::Env::Secrets::Store::Vault;
		return Genesis::Env::Secrets::Store::Vault->provide($env,$service);
	} elsif (ref($service) =~ /^Service::Credhub$/) {
		require Genesis::Env::Secrets::Store::Credhub;
		return Genesis::Env::Secrets::Store::Credhub->provide($env,$service);
	}
}

# }}}
# }}}

### Abstract Instance Methods - must be defined in derived classes {{{

# Informational
# default_mount - returns the default mount point for this class of secrets store {{{
sub default_mount {
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($_[0]), 'default_mount');
	# Input expected:
	#   No arguments
	#
	# Output expected:
	#   String for the default mount point for secrets if user doesn't override.
}

# }}}
# mount - returns the mount point for this secrets store {{{
sub mount {
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($_[0]), 'mount');
	# Input expected:
	#   No arguments
	#
	# Output expected:
	#   String for the mount point for this secrets store.
}

# }}}
# default_slug - the default subpath for the environment based on its name and type {{{
sub default_slug {
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($_[0]), 'default_slug');
	# Input expected:
	#   No arguments
	#
	# Output expected:
	#   String for the default subpath point for this secrets store.
}

# }}}
# slug - the subpath for the given environment {{{
sub slug {
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($_[0]), 'slug');
	# Input expected:
	#   No arguments
	#
	# Output expected:
	#   String for the subpath for this secrets store based on the environment.
}

# }}}
# label - descriptive string for the secret store for this environment {{{
sub label {
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($_[0]), 'label');
	# Input expected:
	#   No arguments
	#
	# Output expected:
	#   String for the describing the secret store for this environment.
}

# }}}

# Basic Access
# list - returns an array of existing secrets, given an optional filter {{{
sub list {
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($_[0]), 'list');
	# Input expected:
	#   filter: either a string, regular expression or a hash that describes a
	#           filter on the name or type or feature of the secrets.  String
	#           matches a path prefix, regular expressions are applied to path
	#           (or keys if included
	#   keys:   returns keys if set to true, false (default) will only return
	#           secrets paths that match the filter.
	#
	# Output expected:
	#   List of matching secret paths under the base path for the secret store for this environment.
}

# }}}
# get - get the secrets under the given path (and optional key) {{{
sub get {
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($_[0]), 'get');
	# Input expected:
	#   path:         store secret path to return the values for
	#   list of keys: a subset of keys to return values for.  (optional - all keys
	#                 returned if not set)
	#
	# Output expected:
	#   Single value if a single path and key are specified, a hash ref if just a
	#   path is specified, or if more than one key is specified.
	#   undef if path not exist, or for each specified key that does not exist.
}

# }}}
# set - write the secret value for the given path, and optional type {{{
sub set {
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($_[0]), 'set');
	# Input expected:
	#   path:   store secret path to set values for
	#   values: The value to store at the given secret path.  If this is a scalar,
	#           it will be stored under the `value` key.  If it is a hash, each
	#           specified key will be set to each specified value for that key.
	#           It will not remove any existing keys.
	#
	# Output expected:
	#   values set if successful, raises error otherwise
}

# }}}

# Connectivity

# authenticate - authenticate to the remote store service {{{
sub authenticate {
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($_[0]), 'authenticate');
	# Input expected:
	#   No Arguments
	#
	# Output expected:
	#   Self if authenticated, raises error otherwise.
}

# }}}
# is_authenticated - determine if already authenticated to the remote store service {{{
sub is_authenticated {
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($_[0]), 'is_authenticated');
	# Input expected:
	#   No Arguements
	#
	# Output expected:
	#   1 if authenticated, undef if not.
}

# }}}
# is_available - determine if remote store service is reachable and targetable {{{
sub is_available {
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($_[0]), 'is_available');
	# Input expected:
	#   No arguments
	#
	# Output expected:
	#   1 if reachable, undef if not.
}

# }}}
#
# # Secrets Generation and Validation
#
# generate - generate secrets based on the environment {{{
sub generate {
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($_[0]), 'generate');
	# Input expected:
	#   options: determine how/what secrets are generated
	#     filter:  filter for which secrets to add
	#     verbose: 1 is full output, 0 is progress-line style
	#
	# Output expected:
	#   1 if successful, 0 otherwise
	#
	# # TODO process_kit_secret_plans(
	#	my $processing_opts = {
	#				level=>$opts{verbose}?'full':'line'
	#			};
	#			$self,
	#			sub{$self->_secret_processing_updates_callback('add',$processing_opts,@_)},
}

# }}}
# validate - validate secrets based on the environment {{{
sub validate {
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($_[0]), 'validate');
	# Input expected:
	#   options: determine how/what secrets are validated
	#     filter:   filter for which secrets to validate
	#     verbose:  1 is full output, 0 is progress-line style with only failures reported
	#     validate: 1 for full validation, 0 to just check existance
	#
	# Output expected:
	#   1 if successful, 0 otherwise
	#
	# Notes:
	#		my $action = $opts{validate} ? 'validate' : 'check';
	#			my $processing_opts = {
	#				level=>$opts{verbose}?'full':'line'
	#			};
	#			#TODO: validate_kit_secrets(
	#			$self,
	#		sub{$self->_secret_processing_updates_callback($action,$processing_opts,@_)},
	#
}

# }}}
# regenerate - regenerate secrets {{{
sub regenerate {
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($_[0]), 'regenerate');
	# Input expected:
	#   options: determine how/what secrets are regenerated
	#     filter:      filter for which secrets to regenerate
	#     verbose:     1 is full output, 0 is progress-line style with only failures reported
	#     validate:    1 for full validation, 0 to just check existance
	#     no_prompt:   Don't prompt for confirmation to regenerate secrets
	#     interactive: Prompt to regenerate each secret individually
	#     invalid:     Only regenerate invalid secrets
	#     renew:       Renew time-sensitive secrets (ie x509) without invalidating the signing key
	#

	#
	# Output expected:
	#   List of matching secret paths under the base path for the secret store for this environment.
		 #Determine secrets_store from kit - assume vault for now (credhub ignored)
		#my $processing_opts = {
			#no_prompt => $opts{'no-prompt'},
			#level=>$opts{verbose}?'full':'line'
		#};
		#$opts{filter} = delete($opts{paths}) if $opts{paths};  renamed option
		#my $ok = $self->secret_store->rotate(
			#$self,
			#sub{$self->_secret_processing_updates_callback($action,$processing_opts,@_)},
			#get_opts(\%opts, qw/filter no_prompt interactive invalid renew/)
		#);
}

# }}}
# remove - remove specific secrets as defined by a filter {{{
sub remove {
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($_[0]), 'remove');
	# Input expected:
	#   filter: either a string, regular expression or a hash that describes a filter on the name or type or feature of the secrets
	#
	# Output expected:
	#   List of matching secret paths under the base path for the secret store for this environment.
		#my $processing_opts = {
		#  level=>$opts{verbose}?'full':'line'
		#};
		#$self,
		#sub{$self->_secret_processing_updates_callback('remove',$processing_opts,@_)},
}

# }}}
# remove_all - remove all secrets under a given path {{{
sub remove_all {
	bug("Abstract Method: Expecting %s class to define concrete '%' method", ref($_[0]), 'remove_all');
	# Input expected:
	#   filter: either a string, regular expression or a hash that describes a filter on the name or type or feature of the secrets
	#
	# Output expected:
	#   List of matching secret paths under the base path for the secret store for this environment.
	# TODO self->vault->query('rm', '-rf', $self->secrets_base);
		 #my @paths = $store->secrets; #TODO ie paths under($self->secrets_base);
		 #return 2 unless scalar(@paths);

		 #unless ($opts{'no-prompt'}) {
		 #  die_unless_controlling_terminal "#R{[ERROR] %s", join("\n",
		 #    "Cannot prompt for confirmation to remove all secrets outside a",
		 #    "controlling terminal.  Use #C{-y|--no-prompt} option to provide confirmation",
		 #    "to bypass this limitation."
		 #  );
		 #  explain "\n#Yr{[WARNING]} This will delete all %s secrets under '#C{%s}', including\n".
		 #               "          non-generated values set by 'genesis new' or manually created",
		 #     scalar(@paths), $store->label;
		 #  while (1) {
		 #    my $response = prompt_for_line(undef, "Type 'yes' to remove these secrets, 'list' to list them; anything else will abort","");
		 #    print "\n";
		 #    if ($response eq 'list') {
		 #      # TODO: check and color-code generated vs manual entries
		 #      my $prefix_len = length($store->base)-1;
		 #      bullet $_ for (map {substr($_, $prefix_len)} @paths);
		 #    } elsif ($response eq 'yes') {
		 #      last;
		 #    } else {
		 #      explain "\nAborted!\nKeeping all existing secrets under '#C{%s}'.\n", $self->secrets_base;
		 #      return 0;
		 #    }
		 #  }
		 #}
		 #waiting_on "Deleting existing secrets under '#C{%s}'...", $store->base;
		 #my ($out,$rc) = $store->remove_all_secrets;
}

# }}}

### Instance Methods {{{

# path_separator - string used to separate secrets components {{{
sub path_separator {
	'/'
}

# }}}
# key_separator - string used to separate the secrets path from the key {{{
sub key_separator {
	':'
}

# }}}
# base - the base secrets path for this environment {{{
sub base {
	my $self = shift;
	$self->mount . $self->slug;
}

# }}}
# path - the full path for the secret (and optional key) in this secrets store {{{
sub path {
	my ($self,$secrets_path, $key) = @_;

	join($self->path_separator, $self->base, (ref($secrets_path) eq "ARRAY" ? @{$secrets_path} : $secrets_path)).
	defined($key) ? $self->key_separator . $key : '';
}

# }}}
# }}}



1;
# vim: fdm=marker:foldlevel=1:noet
