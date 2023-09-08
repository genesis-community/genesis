package Genesis::Commands::Info;

use strict;
use warnings;

use Genesis;
use Genesis::Commands;
use Genesis::Top;

use Cwd      qw/getcwd abs_path/;
use JSON::PP qw/encode_json/;

sub info {
	# TODO: Make use of terminal_width and wrap to make this look better

	command_usage(1) if @_ != 1;

	my ($name) = @_;
	my $env = Genesis::Top->new('.')->load_env($name)->with_vault();

	my @hooks = grep {$env->kit->has_hook($_)} qw(info);
	$env->download_required_configs(@hooks);

	explain "\n#c{%s}\n\n#C{%s Deployment for Environment '}#M{%s}#C{'}\n",
		"="x80, uc($env->type), $env->name;

	my $exodus = $env->exodus_lookup("",{});
	my $unknown = csprintf("#YI{unknown}");
	if ($exodus->{dated}) {
		explain("  #I{Last deployed} %s",
			strfuzzytime($exodus->{dated}, "#C{%~} #K{(%I:%M%p on %b %d, %Y %Z)}"));
		explain("  #I{           by} #C{%s}",
			$exodus->{deployer} || $unknown);
		if ($exodus->{bosh}) {
			if ($exodus->{bosh} eq "(none)" || $exodus->{bosh} eq '~' || $exodus->{use_create_env}) {
				explain(
					"  #I{     %s BOSH} #CI{create-env}",
					(defined($exodus->{as_director}) && !$exodus->{as_director}) ? 'via' : ' as'
				);
			} else {
				explain("  #I{      to BOSH} #CI{%s}",$exodus->{bosh});
			}
		}
		explain("  #I{ based on kit} #C{%s}#C{/%s}%s%s",
			$exodus->{kit_name}||$unknown,
			$exodus->{kit_version}||$unknown,
			($exodus->{kit_is_dev} ? " #y{(dev)}" : ''),
			($env->kit->version ne $exodus->{kit_version}||'' ? " -- #Y{local file specifies ${\($env->kit->id)}!}" : '')
		);
		explain("  #I{        using} #C{Genesis v%s}",
			$exodus->{version} ||$unknown);

		my ($manifest_path,$exists,$sha1) = $env->cached_manifest_info;
		my $pwd = Cwd::abs_path(Cwd::getcwd);
		$manifest_path =~ s#^$pwd/##;
		if ($exists) {
			if (! defined($exodus->{manifest_sha1})) {
				explain "\n  #R{[ERROR]} Cannot confirm local cached deployment manifest pertains to this\n"
						. "          deployment -- perform another deployment to correct this problem."
			} elsif ($exodus->{manifest_sha1} ne $sha1) {
				explain "\n  #Y{[WARNING]} Latest deployment does not match the local cached deployment\n"
							. "             manifest, perhaps you need to perform a #C{git pull}."
			} else {
				explain "  #I{with manifest} #C{%s} #K{(redacted)}", $manifest_path;
			}
		} else {
			explain "\n  #Y{[WARNING]} No local cashed deployment manifest found for this environment,\n"
					. "            perhaps you need to perform a #C{git pull}."
		}
		if ($exodus->{features}) {
			my @features = split(',',$exodus->{features});
			my $msg = "\n       #I{Features} ";
			if (@features) {
				$msg .= "#C{".join("}\n                #C{",@features)."}";
			} else {
				$msg .= "#Ci{None}";
			}
			explain $msg;
		}

		if ($env->has_hook('info')) {
			explain "\n#c{%s}\n", "-"x80;
			$env->run_hook('info');
		}
	} else {
		explain "  #YI{No record of deployment found -- info available only after deployment!}"
	}

	explain "\n#c{%s}\n", "="x80;
}

sub lookup {
	command_usage(1) if @_ < 2 or @_ > 3;
	get_options->{exodus} = 1 if get_options->{'exodus-for'};
	command_usage(1,"#R{[ERROR]} Can only specify one of --merged, --partial, --deployed, or --exodus(-for)")
		if ((grep {$_ =~ /^(exodus|deployed|partial|merged|env)$/} keys(%{get_options()})) > 1);

	my ($name, $key, $default) = @_;
	# Legacy support -- previous versions used key/name order
	my $top = Genesis::Top->new('.');
	($name, $key) = ($key,$name) if !$top->has_env($name) && $top->has_env($key);

	if (get_options->{"defined"}) {
		usage(1, "#R{[ERROR]} Cannot specify default value with --defines option")
			if defined($default);
		$default = bless({},"NotFound"); # Impossible to have this value in sources.
	}
	my $env = $top->load_env($name);
	my $v;
	if (get_options->{merged}) {
		die "Circular reference detected while trying to lookup merged manifest of $name\n"
			if envset("GENESIS__LOOKUP_MERGED_MANIFEST");
		$ENV{GENESIS__LOOKUP_MERGED_MANIFEST}="1";
		$env->download_required_configs('manifest');
		$v = $env->manifest_lookup($key,$default);
	} elsif (get_options->{partial}) {
		die "Circular reference detected while trying to lookup merged manifest of $name\n"
			if envset("GENESIS__LOOKUP_MERGED_MANIFEST");
		$ENV{GENESIS__LOOKUP_MERGED_MANIFEST}="1";
		$v = $env->partial_manifest_lookup($key,$default);
	} elsif (get_options->{deployed}) {
		$v = $env->last_deployed_lookup($key,$default);
	} elsif (get_options->{exodus}) {
		$v = $env->exodus_lookup($key,$default,get_options->{'exodus-for'})
	} elsif (get_options->{env}) {
		my %envvars = $env->get_environment_variables();
		$key =~ s/^\.//;
		if ($key) {
			$v = exists($envvars{$key}) ? $envvars{$key} :
					 exists($ENV{$key}) ? $ENV{$key} : $default;
		} else {
			$v = {%ENV, %envvars};
		}
	} else {
		$v = $env->lookup($key, $default);
	}

	if (get_options->{defined}) {
		exit(ref($v) eq "NotFound" ? 4 : 0);
	} elsif (defined($v)) {
		$v = encode_json($v) if ref($v);
		print "$v\n";
	}
	exit 0;
}

sub yamls {
	option_defaults(
		"include-kit" => 0
	);
	command_usage(1) if @_ != 1;

	my $env = Genesis::Top
		->new('.')
		->load_env($_[0])
		->download_required_configs('blueprint');
	my @files = $env->format_yaml_files(%{get_options()});
	explain join("\n", @files)."\n";
}

sub kit_manual {
	my ($name) = @_;
	my $top = Genesis::Top->new('.');
	my @possible_kits = keys %{$top->local_kits};
	push @possible_kits, 'dev' if $top->has_dev_kit;

	bail "No local kits found; you must specify the name of the kit to fetch"
		unless scalar(@possible_kits);

	my $kit;
	$name ||= '';
	if ($name && $top->has_env($name)) {
		$top->reset_vault();
		# TODO: provide a vaultless way to read env kit without vault
		$kit = $top->load_env($name)->kit;
	} elsif ($name && $name eq 'dev') {
		$kit = $top->local_kit_version('dev')
	} else {
		my ($kit_name,$version) = $name =~ m/^([^\/]*)(?:\/(.*))?$/;
		if (!$version && semver($name)) {
			bail "More than one local kit found; please specify the kit to get the manual for"
				if scalar(@possible_kits) > 1;
			$version = $name;
			$version =~ s/^v//;
			$name = $possible_kits[0];
		}
		$kit = $top->local_kit_version($name, $version);
	}

	if(!(defined $kit)) {
		error "Kit not found: #C{%s}", $name;
		exit 1;
	}

	explain STDERR "Displaying manual for kit #C{%s}...\n", $kit->id;

	my $man = $kit->path('MANUAL.md');
	if (-f $man) {
		run({ interactive => 1 }, 'less "$1"', $man);
		exit 0;
	}
	explain STDERR "#Y{%s} has no MANUAL.md", $kit->id;
	exit 1;
}

1;
