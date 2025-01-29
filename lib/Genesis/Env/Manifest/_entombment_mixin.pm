# Mixin to provide entombment functionality - require to use;

use Digest::SHA qw/sha1_hex/;

use Genesis qw/info bail read_json_from lines/;
use Genesis::Term qw/terminal_width/;

use Service::Vault::Local;
use Service::Credhub;

sub local_vault {
	return Service::Vault::Local->create($_[0]->env->name);
}

sub _entomb_secrets {
	my ($self, $data) = @_;

	return 1 if $self->{entombed}; # don't do this more than once...

	$self->env->notify("entombing secrets into Credhub for enhanced security...");
	my $src_vault = $self->env->vault;
	info (
		{pending => 1},
		"[[  - >>determining vault paths used by manifest from %s...",
		$src_vault->name
	);
	$self->builder->unevaluated(); # Prewarm cache
	my $secret_paths = $self->get_vault_paths(notify=>0);
	my $secrets_count = scalar(keys %$secret_paths);
	if ($secrets_count) {
		info "found %d paths.", $secrets_count;
		my %secret_keys = ();

		info (
			{pending => 1},
			"[[  - >>retrieving secrets from used vault paths...",
		);
		for (keys %$secret_paths) {
			my ($s,$k) = split ":", $_, 2;
			$s =~ s#^/?#/#; # make sure the secret path starts with a /
			push(@{$secret_keys{$s}}, $k)
		}
		my %secret_values = %{
			scalar(read_json_from(
				$src_vault->query({redact_output => 1},"export", keys %secret_keys)
			))
		};
		# BUG FIX for safe export on similar names
		for (map {substr($_,1)} keys %secret_keys) {
			$secret_values{$_} = $src_vault->get("/$_")
				unless (defined($secret_values{$_}));
		}
		info ("#g{done!}");

		my $local_vault = $self->_setup_local_vault();

		my $credhub = $self->env->credhub();
		$credhub->preload();

		#Design decision: use value-type credhub for each key, and only populate what is needed.
		my $base_path = $self->env->secrets_base();
		my $idx = 0;
		my $w = length("$secrets_count");
		my $entombment_prefix = "genesis-entombed/"; # can be set to another value to prevent conflicts if needed
		info(
			"[[  - >>copying Vault values to Credhub: #c{%s} => #B{%s}:",
			$base_path, $credhub->base().($entombment_prefix ? "$entombment_prefix" : "")
		);

		my $previous_lines=0;
		my %results = (new => 0, failed => 0, altered => 0, 'exists' => 0);
		for my $secret (sort keys %secret_keys) {
			my $vault_label = $secret;
			$vault_label =~ s/^$base_path(.*)/csprintf("#C{$1}")/e;
			my $cred_path = $secret;
			$cred_path =~ s/^$base_path//;
			$cred_path =~ s#^/#_/#;
			for my $key (sort @{$secret_keys{$secret}}) {
				my $value = $secret_values{substr($secret,1)}{$key};
				my ($credhub_var, $secret_sha, $action, $action_color, $existing) = $self->_entomb_secret(
					$local_vault, $secret, $key, $value, $credhub, $cred_path, $entombment_prefix
				);
				$results{$action} += 1;
				my $msg = wrap(sprintf(
					"[[    [%*d/%*d] >>%s:#c{%s} #Kk{[sha1: }#Wk{%s}#Kk{]} #G{=>} #B{%s} ...#%s{%s}",
					$w, ++$idx, $w, $secrets_count, "#y{$vault_label}", $key, $secret_sha,
					$credhub_var, $action_color, $action
				), terminal_width);
				print STDERR "\r[A[2K" for (1..$previous_lines);
				info $msg;
				$previous_lines=($existing && $existing eq $value) ? scalar(lines($msg)) : 0;
			}
		}
		print STDERR "\r[A[2K" for (1..$previous_lines);
		# FIXME: use pretty_duration and style consistent with *_secrets output
		info(
			"[[  - >>$idx of $secrets_count secrets processed: %s new, %s already exist, %s altered, %s failed",
			@results{('new','exists','altered','failed')}
		);

		bail(
			"Failed to entomb one or more secrets into Credhub.  This may be due ".
			"to a bug in Genesis, communication or authentication error with ".
			"Credhub, or a value that Credhub can't support.\n\n".
			"Please try again without the --entomb option if used, or if deploying, ".
			"use the --no-entomb option, if this persists.\n\n".
			"Please contact the Genesis team, or open a issue on ".
			"#Bu{%s/issues/new}",
			$Genesis::GITHUB
		) if ($results{failed});

		$self->{entombed} = 1;
		return 1
	} else {
		info "no vault paths in use.\n";
		return 0
	}
}

sub _setup_local_vault {
	my ($self) = @_;
	info (
		{pending => 1},
		"[[  - >>starting local in-memory vault to hold references to Credhub...",
	);
	my $local_vault = $self->local_vault;
	info ("#g{done!}");
	return $local_vault;
}

sub _entomb_secret {
	my ($self, $local_vault, $vault_path, $key, $value, $credhub, $cred_path, $entombment_prefix) = @_;
	$entombment_prefix //= 'genesis-entombed/';
	my $secret_sha = substr(sha1_hex("$cred_path--$key--".$value),0,8);
	my $cred_name = "$entombment_prefix$cred_path--$key--$secret_sha";
	my $credhub_var = "(($cred_name))";
	my $existing = $credhub->get($cred_name);
	my $action_color = "yi";
	my $action = "exists";
	unless ($existing && $existing eq $value) {
		$credhub->set($cred_name, $value);
		my $new_value = $credhub->get($cred_name);
		if ($new_value ne $value) {
			$action = "failed";
			$action_color = "Yr";
		} else {
			$action = $existing ? "altered" : "new";
			$action_color = $existing ? "ri" : "gi";
		}
	}
	$local_vault->set($vault_path, $key, $credhub_var);
	return ($credhub_var, $secret_sha, $action, $action_color, $existing);
}

1;
