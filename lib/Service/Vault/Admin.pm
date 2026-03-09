package Service::Vault::Admin;
use v5.20;
use warnings;

use Genesis qw/bail info run debug trace/;
use Genesis::UI qw/prompt_for_boolean/;
use JSON::PP qw/decode_json/;

# new - create a new Vault::Admin instance {{{
sub new {
	my ($class, $vault) = @_;
	bail("Service::Vault::Admin requires a Service::Vault object")
		unless $vault && ref($vault) =~ /^Service::Vault/;

	return bless({
		vault => $vault
	}, $class);
}
# }}}

sub approles {
	my ($self) = @_;
	return $self->{__approle_service} //= Service::Vault::Admin::AppRole->new($self);
}

sub policies {
	my ($self) = @_;
	return $self->{__policy_service} //= Service::Vault::Admin::Policy->new($self);
}

# vault - get the associated vault object {{{
sub vault {
	return $_[0]->{vault};
}
# }}}



# create_policy - create a vault policy {{{
sub create_policy {
	my ($self, $policy_name, $policy_content, %opts) = @_;

	bail("Policy name is required") unless $policy_name;
	bail("Policy content is required") unless $policy_content;

	my $overwrite = $opts{overwrite} // 0;
	my $prompt = $opts{prompt} // 1;

	# Check if policy exists
	if ($self->policy_exists($policy_name)) {
		if ($prompt && !$overwrite) {
			my $continue = prompt_for_boolean(
				"Policy #C{$policy_name} already exists. Do you want to overwrite it?",
				0
			);
			return 0 unless $continue;
		} elsif (!$overwrite) {
			debug("Policy #C{$policy_name} already exists, skipping creation");
			return 0;
		}
	}

	info("Creating policy #C{$policy_name}...");

	# Write policy using safe vault policy write
	my ($output, $rc) = $self->vault->query(
		{stdin => $policy_content},
		'vault policy write', $policy_name, '-'
	);

	if ($rc) {
		bail("Failed to create policy #C{$policy_name}: $output");
	}

	info("#G{[OK]} Policy #C{$policy_name} created");
	debug("Policy content:\n#K{$policy_content}");

	return 1;
}
# }}}

# policy_exists - check if a policy exists {{{
sub policy_exists {
	my ($self, $policy_name) = @_;

	my ($output, $rc) = $self->vault->query({stderr => 0}, 'vault policy list');
	return 0 if $rc;

	my @policies = split(/\n/, $output);
	return grep { $_ eq $policy_name } @policies;
}
# }}}

# create_approle - create an AppRole with specified configuration {{{
sub create_approle {
	my ($self, $role_name, %config) = @_;

	bail("AppRole name is required") unless $role_name;

	my $overwrite = delete $config{overwrite} // 0;
	my $prompt = delete $config{prompt} // 1;

	# Set defaults
	my %defaults = (
		secret_id_ttl => '0',
		token_num_uses => '0',
		token_ttl => '60m',
		token_max_ttl => '60m',
		secret_id_num_uses => '0',
		policies => "default,$role_name"
	);

	%config = (%defaults, %config);

	# Check if role exists
	if ($self->approles->exists($role_name)) {
		if ($prompt && !$overwrite) {
			my $continue = prompt_for_boolean(
				"AppRole #C{$role_name} already exists. Do you want to recreate it?",
				0
			);
			return unless $continue;
		} elsif (!$overwrite) {
			debug("AppRole #C{$role_name} already exists, skipping creation");
			return;
		}

		# Delete existing role
		debug("Deleting existing AppRole #C{$role_name}");
		$self->vault->query({stderr => 0}, 'vault delete', "auth/approle/role/$role_name");
	}

	info("Creating AppRole #C{$role_name}...");

	# Build vault write command arguments
	my @args = ("auth/approle/role/$role_name");
	for my $key (sort keys %config) {
		push @args, "${key}=$config{$key}";
	}

	my ($output, $rc) = $self->vault->query('vault write', @args);

	if ($rc) {
		bail("Failed to create AppRole #C{$role_name}: $output");
	}

	info("#G{[OK]} AppRole #C{$role_name} created");
	return 1;
}
# }}}

# get_approle_credentials - get role-id and secret-id for an AppRole {{{
sub get_approle_credentials {
	my ($self, $role_name) = @_;

	bail("AppRole name is required") unless $role_name;
	bail("AppRole #C{$role_name} does not exist") unless $self->approles->exists($role_name);

	# Get role-id
	my ($role_id, $rid_rc) = $self->vault->query(
		'vault read', '-field=role_id', "auth/approle/role/$role_name/role-id"
	);
	chomp($role_id) if defined $role_id;

	# Generate new secret-id
	my ($secret_id, $sid_rc) = $self->vault->query(
		'vault write', '-field=secret_id', '-f', "auth/approle/role/$role_name/secret-id"
	);
	chomp($secret_id) if defined $secret_id;

	if ($rid_rc || $sid_rc) {
		bail("Failed to retrieve credentials for AppRole #C{$role_name}");
	}

	return ($role_id, $secret_id);
}
# }}}

# store_approle_credentials - store AppRole credentials in vault {{{
sub store_approle_credentials {
	my ($self, $role_name, $storage_path, $role_id, $secret_id) = @_;

	bail("All parameters are required") unless $role_name && $storage_path && $role_id && $secret_id;

	info("Storing credentials for AppRole #C{$role_name} at #M{$storage_path}");

	# Store role-id and secret-id
	$self->vault->set($storage_path, 'approle-id', $role_id);
	$self->vault->set($storage_path, 'approle-secret', $secret_id);

	info("#G{[OK]} Credentials stored at #M{$storage_path}");
	return 1;
}
# }}}

# setup_concourse_approle - setup AppRole for Concourse {{{
sub setup_concourse_approle {
	my ($self, %opts) = @_;

	my $role_name = $opts{role_name} || 'concourse';
	my $prompt = $opts{prompt} // 1;
	my $concourse_path = $opts{concourse_path} || '/concourse';
	my $storage_base = $opts{storage_base} || $ENV{GENESIS_SECRETS_BASE};

	if ($prompt) {
		my $create = prompt_for_boolean(
			"Do you want to install the #C{$role_name} AppRole?",
			1
		);
		return unless $create;
	}

	# Ensure AppRole is enabled
	$self->approles->enable();

	# Create policy for Concourse
	my $policy_content = qq{
path "${concourse_path}/*" {
  capabilities = ["create", "read", "update", "list", "delete"]
}
};

	$self->create_policy($role_name, $policy_content, %opts);

	# Create AppRole
	$self->create_approle($role_name, %opts);

	# Get credentials
	my ($role_id, $secret_id) = $self->get_approle_credentials($role_name);

	# Store credentials
	my $storage_path = $storage_base . $role_name;
	$self->store_approle_credentials($role_name, $storage_path, $role_id, $secret_id);

	info("#G{[DONE]} AppRole #C{$role_name} setup complete");
	return 1;
}
# }}}

# setup_genesis_pipelines_approle - setup AppRole for Genesis pipelines {{{
sub setup_genesis_pipelines_approle {
	my ($self, %opts) = @_;

	my $role_name = $opts{role_name} || 'genesis-pipelines';
	my $prompt = $opts{prompt} // 1;
	my $exodus_mount = $opts{exodus_mount} || $ENV{GENESIS_EXODUS_MOUNT};
	my $storage_base = $opts{storage_base} || $ENV{GENESIS_CI_MOUNT};

	bail("Cannot find mount for exodus path") unless $exodus_mount;

	if ($prompt) {
		my $create = prompt_for_boolean(
			"Do you want to install the #C{$role_name} AppRole?",
			1
		);
		return unless $create;
	}

	# Ensure AppRole is enabled
	$self->approles->enable();

	# Create policy for Genesis pipelines
	my $policy_content = qq{
path "${exodus_mount}metadata/*" {
  capabilities = ["create", "read", "update", "list", "delete"]
}
};

	$self->create_policy($role_name, $policy_content, %opts);

	# Create AppRole
	$self->create_approle($role_name, %opts);

	# Get credentials
	my ($role_id, $secret_id) = $self->get_approle_credentials($role_name);

	# Store credentials
	my $storage_path = $storage_base . $role_name;
	$self->store_approle_credentials($role_name, $storage_path, $role_id, $secret_id);

	info("#G{[DONE]} AppRole #C{$role_name} setup complete");
	return 1;
}
# }}}

1;
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
