package Genesis::Env::Secrets::Parser::FromManifest;

use strict;
use warnings;

use base 'Genesis::Env::Secrets::Parser';

use Genesis;
use Genesis::Secret::Invalid;
use Genesis::Secret::RSA;
use Genesis::Secret::Random;
use Genesis::Secret::SSH;
use Genesis::Secret::X509;
use Genesis::Secret::UserProvided;

# Instance Methods
sub parse {
	my ($self,%opts) = @_;
	my @secrets = ();
	logger->info({pending =>1},
		"[[  - >>fetching secret definitions from manifest variables block ... "
	) if $opts{notify};
	my $t = time_exec(sub{$self->env->manifest_provider->partial(subset=>'credhub_vars')->data});
	my $metadata = $self->env->manifest_provider->partial(subset=>'credhub_vars')->data;
	my %boshvars = %{$metadata->{'bosh-variables'}||{}};
	my $variables = $metadata->{'variables'};
	if (%boshvars && $variables) {
		require JSON::PP;
		my $varsjson = JSON::PP::encode_json($variables);
		my $changes = $varsjson =~ s/\(\(([^ \)]+)\)\)/$boshvars{$1}\/\/"(($1))"/eg;
		$variables = JSON::PP::decode_json($varsjson);
	}
	for my $defn (@{$variables//[]}) {
		my ($name, $type) = @$defn{qw(name type)};
		if ($type eq 'certificate') {
			push @secrets, $self->_parse_certificate(%$defn)
		} elsif ($type eq 'password') {
			push @secrets, $self->_parse_password(%$defn)
		} elsif ($type eq 'rsa') {
			push @secrets, $self->_parse_rsa(%$defn)
		} elsif ($type eq 'ssh') {
			push @secrets, $self->_parse_ssh(%$defn)
		} else {
			push @secrets, Genesis::Secret::Invalid->new(
				"$name",
				subject  => "$type variable definition",
				errors   => "Unknown variable type",
				data     => $defn,
				_ch_name => $name
			)
		}
	}

	# Existing legacy kit support
	if ($self->env->kit->id =~ /^cf\/2.*/) {
		require Genesis::Env::Secrets::Parser::_legacy_cf_support_mixin;
		process_legacy_cf_secrets(\@secrets, [$self->env->features]);
	}

	logger->info(
		"#%s{found %s}", scalar(@secrets) ? 'G' : 'B', scalar(@secrets)
	) if $opts{notify};
	return @secrets;
}

sub _parse_password {
	my ($self, %opts) = @_;
	my $path = $opts{name};
	my $size = $opts{options}{length} // 30;
	my $policy = "";
	$policy .= 'A-Z' unless $opts{options}{exclude_upper};
	$policy .= 'a-z' unless $opts{options}{exclude_lower};
	$policy .= '0-9' unless $opts{options}{exclude_number};
	#$policy .= '' unless $opts{options}{exclude_special}; TBD

	return Genesis::Secret::Random->new(
		$path.":password",
		size        => $size,
		format      => undef,
		destination => undef,
		valid_chars => $policy,
		fixed       => $opts{metadata}{fixed}?1:0,
		_ch_name    => $path,
	);
}

sub _parse_ssh {
	my ($self, %opts) = @_;
	my $path = $opts{name};
	my $size = $opts{options}{key_length} // 2048;
	return Genesis::Secret::SSH->new(
		$path, size => $size, fixed => 0, _ch_name => $path
	)
}

sub _parse_rsa {
	my ($self, %opts) = @_;
	my $path = $opts{name};
	my $size = $opts{options}{key_length} // 2048;
	return Genesis::Secret::RSA->new(
		$path, size => $size, fixed => 0, _ch_name => $path
	)
}

sub _parse_certificate {
	my ($self, %opts) = @_;
	my $path = $opts{name};

	my $duration = $opts{options}{duration};
	$duration = defined($duration)
		? $duration.'d'
		: $opts{options}{is_ca} ? '10y' : '3y';

	my @names = @{$opts{options}{alternative_names}//[]};

	# Special Case v2.0.x CF Kit
	if ($self->env->kit->id =~ /^cf\/2.0/) {
		if ($path eq 'nats_server_cert') {
			@names = (
				"nats.service.cf.internal",
				"*.nats.service.cf.internal"
			)
		}

		my $subject_cn = $opts{options}{common_name};
		push @names, $subject_cn
			if (!scalar(@names) && $subject_cn);
	}

	return Genesis::Secret::X509->new(
		$path,
		is_ca      => !!$opts{options}{is_ca}//0,
		signed_by  => $opts{options}{ca},
		valid_for  => $duration,
		subject_cn => $opts{options}{common_name},
		names      => [@names],
		usage      => $opts{options}{extended_key_usage},
		_ch_name   => $path
	);
}

1;
# vim: fdm=marker:foldlevel=1:noet
