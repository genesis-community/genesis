package Service::Vault::Admin::AppRole;

use v5.20;
use warnings;
use Genesis qw/bail info run debug trace read_json_from/;

sub new {
	my ($class, $admin) = @_;
	bail("Service::Vault::Admin::AppRole requires a Service::Vault::Admin object")
		unless $admin && ref($admin) =~ /^Service::Vault::Admin/;

	return bless({
		admin => $admin
	}, $class);
}

sub vault {
	return $_[0]->{admin}->{vault};
}

# enabled - check if AppRole auth method is enabled {{{
sub enabled {
	my ($self) = @_;
	my ($auths, $rc, $err) = read_json_from(
		$self->vault->query(qw/vault auth list --format=json/)
	);
	bail("Failed to list auth methods: $err") if $rc;
	return exists $auths->{'approle/'};

}

# }}}
sub enable {
	my ($self) = @_;
	return 1 if $self->enabled();

	my ($output, $rc, $err) = $self->vault->query(qw/vault auth enable approle/);
	bail("Failed to enable AppRole auth method: $err") if $rc;
	return 1;
}

# list - list all existing AppRoles {{{
sub list {
	my ($self) = @_;

	my ($roles, $rc, $env) = read_json_from(
		$self->vault->query({stderr => 0}, qw{vault list -format=json auth/approle/role})
	);
	return () if $rc;
	return @$roles;
}
# }}}

# exists - check if an AppRole exists {{{
sub exists {
	my ($self, $role_name) = @_;

	my @roles = $self->list();
	return grep { $_ eq $role_name } @roles;
}
# }}}

1
