package Genesis::Commands::Ocfp::ShowNetwork;

use strict;
use warnings;

use Genesis qw/bail info output struct_lookup sentence_join/;
use Genesis::Term qw/terminal_width csprintf decolorize csize build_markdown_table/;
use IPv4;
use JSON::PP;

# run - Entry point for 'ocfp show network' command {{{
sub run {
	my ($env, %options) = @_;

	my $data = _gather_network_data($env);

	if ($options{subnet}) {
		$data = _filter_by_subnet($data, $options{subnet});
	}

	if ($options{json}) {
		return _output_json($data, %options);
	} elsif ($options{summary}) {
		return _output_summary($data, %options);
	} elsif ($options{reserved}) {
		return _output_reserved($data, %options);
	} elsif ($options{allocated}) {
		return _output_allocated($data, %options);
	} elsif ($options{available}) {
		return _output_available($data, %options);
	} else {
		return _output_full($data, %options);
	}
}

# }}}

# _compute_cidr_info - Sipcalc-style CIDR breakdown {{{
sub _compute_cidr_info {
	my ($cidr) = @_;
	my $span = IPv4->span($cidr);
	my ($prefix_length) = ($cidr =~ m{/(\d+)$});
	$prefix_length += 0; # ensure numeric
	my $netmask  = _netmask_from_prefix($prefix_length);
	my $wildcard = _wildcard_from_netmask($netmask);

	return {
		network         => $span->network->address,
		broadcast       => $span->broadcast->address,
		netmask         => $netmask,
		wildcard        => $wildcard,
		prefix_length   => $prefix_length,
		total_addresses => $span->size,
		usable_hosts    => ($span->size > 2) ? $span->size - 2 : $span->size,
		first_host      => $span->first->address,
		last_host       => $span->last->address,
	};
}

# }}}
# _netmask_from_prefix - Convert prefix length to dotted-decimal netmask {{{
sub _netmask_from_prefix {
	my ($prefix) = @_;
	my $mask = (0xFFFFFFFF << (32 - $prefix)) & 0xFFFFFFFF;
	return join('.', ($mask >> 24) & 0xFF, ($mask >> 16) & 0xFF,
	                 ($mask >> 8) & 0xFF, $mask & 0xFF);
}

# }}}
# _wildcard_from_netmask - Invert netmask to wildcard mask {{{
sub _wildcard_from_netmask {
	my ($netmask) = @_;
	my @octets = split /\./, $netmask;
	return join('.', map { 255 - $_ } @octets);
}

# }}}

# _compute_ranges - Compute available and reserved IP ranges for a subnet {{{
sub _compute_ranges {
	my ($subnet) = @_;
	my $range = IPv4->new($subnet->{cidr_block});

	my $reserved_ips = $subnet->{'reserved-ips'} // {};
	my @reserved_ip_pairs = @{$reserved_ips}{
		sort grep {/^reserved/} keys %$reserved_ips
	};
	my @available_ip_pairs = @{$reserved_ips}{
		sort grep {/^available/} keys %$reserved_ips
	};

	my $explicit_availability = scalar(@available_ip_pairs) > 0;
	my $explicit_reserved     = scalar(@reserved_ip_pairs) > 0;
	@available_ip_pairs = ($range->start->address, $range->end->address)
		unless @reserved_ip_pairs || @available_ip_pairs;
	@reserved_ip_pairs = (
		$range->start->address, $range->start->add(4)->address,
		$range->end->address,   $range->end->address,
	) unless @reserved_ip_pairs;

	my $reserved_range = IPv4->new();
	$reserved_range += [splice(@reserved_ip_pairs, 0, 2)]
		while @reserved_ip_pairs;

	my $available_range = IPv4->new();
	$available_range += [splice(@available_ip_pairs, 0, 2)]
		while @available_ip_pairs;

	if ($explicit_availability) {
		$reserved_range += ($range - $available_range);
	}

	$available_range = $range unless $available_range > 0;
	$available_range -= $reserved_range if $reserved_range > 0;

	return ($available_range->simplify, $reserved_range->simplify);
}

# }}}

# _gather_network_data - Collect all network data into unified structure {{{
sub _gather_network_data {
	my ($env) = @_;

	my $net_config = $env->ocfp_config_lookup(['net','vpc']) // {};
	my $subnets_config = $env->ocfp_config_lookup(['net.subnets','vpc.subnets']) // {};

	my $vpc_cidr = $net_config->{cidr_block} // '';
	my $vpc_info = $vpc_cidr ? _compute_cidr_info($vpc_cidr) : {};

	# Try to get BOSH network data (exodus); gracefully degrade for create-env
	my $bosh_network_data;
	eval {
		$bosh_network_data = $env->director_exodus_lookup('/network');
	};
	$bosh_network_data //= {};

	my %subnets;
	for my $subnet_name (sort keys %$subnets_config) {
		my $subnet = $subnets_config->{$subnet_name};
		my $cidr   = $subnet->{cidr_block};

		my ($available_range, $reserved_range) = _compute_ranges($subnet);

		# Extract claims from BOSH network data
		my $claims = {};
		my $allocated_range = IPv4->new();
		if ($bosh_network_data->{subnets} && $bosh_network_data->{subnets}{$subnet_name}) {
			$claims = $bosh_network_data->{subnets}{$subnet_name}{claims} || {};
			for my $claim_range (values %$claims) {
				$allocated_range += IPv4->new($claim_range) if $claim_range;
			}
		}

		# Free = available minus allocated
		my $free_range = $available_range - $allocated_range;

		$subnets{$subnet_name} = {
			cidr_block      => $cidr,
			cidr_info       => _compute_cidr_info($cidr),
			az              => $subnet->{az} // '',
			gateway         => $subnet->{gateway} // '',
			dns             => $subnet->{dns} // '',
			full_range      => IPv4->new($cidr),
			reserved_range  => $reserved_range,
			available_range => $available_range,
			allocated_range => $allocated_range,
			free_range      => $free_range->simplify,
			named_reserved  => _extract_named_reserved($subnet->{'reserved-ips'} || {}),
			claims          => $claims,
			reserved_ips    => $subnet->{'reserved-ips'} || {},
		};
	}

	return {
		env_name  => $env->name,
		ocfp_type => $env->ocfp_type,
		vpc_cidr  => $vpc_cidr,
		vpc_info  => $vpc_info,
		subnets   => \%subnets,
	};
}

# }}}
# _extract_named_reserved - Get individually named IP reservations {{{
sub _extract_named_reserved {
	my ($reserved_ips) = @_;
	my @named;
	for my $key (sort keys %$reserved_ips) {
		# Skip reserved/available range pairs (reserved_a, available_0, etc.)
		next if $key =~ /^(reserved|available)_[a-z\d]+$/;
		# Skip static allocation flags (network_static)
		next if $key =~ /_static$/;
		# Skip allocation boundary markers (network_a through network_d)
		next if $key =~ /_[a-d]$/;
		# Include individual named IPs (e.g., bosh_ip, director_ip)
		push @named, { name => $key, ip => $reserved_ips->{$key} }
			if $reserved_ips->{$key} =~ /^\d+\.\d+\.\d+\.\d+$/;
	}
	return \@named;
}

# }}}

# _filter_by_subnet - Filter data to a single subnet {{{
sub _filter_by_subnet {
	my ($data, $name) = @_;
	bail("Unknown subnet '%s'. Available subnets: %s",
		$name, join(', ', sort keys %{$data->{subnets}}))
		unless exists $data->{subnets}{$name};

	return {
		%$data,
		subnets => { $name => $data->{subnets}{$name} },
	};
}

# }}}

# Output Functions

# _output_full - Full network overview {{{
sub _output_full {
	my ($data, %opts) = @_;

	# VPC Header
	if ($data->{vpc_cidr}) {
		info("\n#C{VPC Network}: %s  (#mi{%s})\n", $data->{vpc_cidr}, $data->{ocfp_type});
		_display_cidr_section("VPC", $data->{vpc_info}) if $opts{verbose};
	}

	info("\n#Cu{Environment}: %s\n", $data->{env_name});

	for my $subnet_name (sort keys %{$data->{subnets}}) {
		my $s = $data->{subnets}{$subnet_name};
		info("\n%s\n", '-' x 40);
		info("#G{Subnet}: %s  (AZ: %s)\n", $subnet_name, $s->{az});
		info("  CIDR: %s  Gateway: %s  DNS: %s\n",
			$s->{cidr_block}, $s->{gateway}, $s->{dns});

		_display_cidr_section($subnet_name, $s->{cidr_info}) if $opts{verbose};
		_display_utilization_bar($s);
		_display_assignments_section($s, %opts);
		_display_free_section($s);
	}
}

# }}}
# _output_summary - Compact summary table {{{
sub _output_summary {
	my ($data, %opts) = @_;

	my @header = ("Subnet", "CIDR", "AZ", "Reserved", "Allocated", "Free", "Util%");
	my $table = sprintf("| %s |\n", join(' | ', @header));
	$table .= sprintf("|%s|\n", join('|', map { ':' . ('-' x (length($_))) . '-' } @header));

	for my $name (sort keys %{$data->{subnets}}) {
		my $s = $data->{subnets}{$name};
		my $total = $s->{cidr_info}{total_addresses};
		my $reserved_count  = ref($s->{reserved_range})  ? $s->{reserved_range}->size  : 0;
		my $allocated_count = ref($s->{allocated_range}) ? $s->{allocated_range}->size : 0;
		my $free_count      = ref($s->{free_range})      ? $s->{free_range}->size      : 0;
		my $util = $total > 0 ? sprintf("%.0f%%", (($reserved_count + $allocated_count) / $total) * 100) : "N/A";

		$table .= sprintf("| %s | %s | %s | %d | %d | %d | %s |\n",
			$name, $s->{cidr_block}, $s->{az},
			$reserved_count, $allocated_count, $free_count, $util);
	}

	info("\n#Cu{Network Summary}: %s (%s)\n\n", $data->{env_name}, $data->{ocfp_type});
	info("%s\n", build_markdown_table($table));
}

# }}}
# _output_reserved - Reserved IPs only {{{
sub _output_reserved {
	my ($data, %opts) = @_;

	info("\n#Cu{Reserved IPs}: %s\n", $data->{env_name});

	for my $name (sort keys %{$data->{subnets}}) {
		my $s = $data->{subnets}{$name};
		info("\n#G{%s} (%s):\n", $name, $s->{cidr_block});
		_display_reserved_section($s);
	}
}

# }}}
# _output_allocated - Allocated IPs only {{{
sub _output_allocated {
	my ($data, %opts) = @_;

	info("\n#Cu{Allocated IPs}: %s\n", $data->{env_name});

	for my $name (sort keys %{$data->{subnets}}) {
		my $s = $data->{subnets}{$name};
		info("\n#G{%s} (%s):\n", $name, $s->{cidr_block});
		_display_allocated_section($s);
	}
}

# }}}
# _output_available - Free IPs only {{{
sub _output_available {
	my ($data, %opts) = @_;

	info("\n#Cu{Available IPs}: %s\n", $data->{env_name});

	for my $name (sort keys %{$data->{subnets}}) {
		my $s = $data->{subnets}{$name};
		info("\n#G{%s} (%s):\n", $name, $s->{cidr_block});
		_display_available_section($s);
	}
}

# }}}
# _output_json - JSON output {{{
sub _output_json {
	my ($data, %opts) = @_;

	my $json_data = _serialize_for_json($data);
	my $json = JSON::PP->new->utf8->pretty->canonical;
	output($json->encode($json_data));
}

# }}}

# Display Helpers

# _display_assignments_section - Combined reserved + allocated table {{{
sub _display_assignments_section {
	my ($subnet_data, %opts) = @_;

	my @named = @{$subnet_data->{named_reserved} || []};
	my %claims = %{$subnet_data->{claims} || {}};

	return unless @named || %claims;

	my $table = "| Type | Name | IP / Range |\n|:-----|:-----|:-----------|\n";
	for my $entry (@named) {
		$table .= sprintf("| #R{reserved} | %s | %s |\n", $entry->{name}, $entry->{ip});
	}
	for my $network (sort keys %claims) {
		$table .= sprintf("| #Y{allocated} | %s | %s |\n", $network, $claims{$network});
	}
	info("%s\n", build_markdown_table($table));
}

# }}}
# _display_free_section - Compact free range display {{{
sub _display_free_section {
	my ($subnet_data) = @_;

	my $free_size = ref($subnet_data->{free_range}) ? $subnet_data->{free_range}->size : 0;
	return unless $free_size > 0;

	info("  #Gi{Free}: %s\n", $subnet_data->{free_range}->range);
}

# }}}

# _display_cidr_section - Render sipcalc-style CIDR info {{{
sub _display_cidr_section {
	my ($label, $info) = @_;
	return unless $info && $info->{network};

	info("  #Yi{CIDR Info}:\n");
	info("    Network:         %s/%s\n", $info->{network}, $info->{prefix_length});
	info("    Netmask:         %s\n", $info->{netmask});
	info("    Wildcard:        %s\n", $info->{wildcard});
	info("    Broadcast:       %s\n", $info->{broadcast});
	info("    First Host:      %s\n", $info->{first_host});
	info("    Last Host:       %s\n", $info->{last_host});
	info("    Total Addresses: %s\n", $info->{total_addresses});
	info("    Usable Hosts:    %s\n", $info->{usable_hosts});
}

# }}}
# _display_reserved_section - Render reserved IPs table {{{
sub _display_reserved_section {
	my ($subnet_data) = @_;

	my $reserved_size = ref($subnet_data->{reserved_range}) ? $subnet_data->{reserved_range}->size : 0;
	info("  #Ri{Reserved}: %d IPs", $reserved_size);
	if ($reserved_size > 0) {
		info(" (%s)", $subnet_data->{reserved_range}->range);
	}
	info("\n");

	my @named = @{$subnet_data->{named_reserved} || []};
	if (@named) {
		my $table = "| Name | IP |\n|:-----|:---|\n";
		for my $entry (@named) {
			$table .= sprintf("| %s | %s |\n", $entry->{name}, $entry->{ip});
		}
		info("%s\n", build_markdown_table($table));
	}
}

# }}}
# _display_allocated_section - Render allocation/claims table {{{
sub _display_allocated_section {
	my ($subnet_data) = @_;

	my $allocated_size = ref($subnet_data->{allocated_range}) ? $subnet_data->{allocated_range}->size : 0;
	info("  #Yi{Allocated}: %d IPs", $allocated_size);
	if ($allocated_size > 0) {
		info(" (%s)", $subnet_data->{allocated_range}->range);
	}
	info("\n");

	my %claims = %{$subnet_data->{claims} || {}};
	if (%claims) {
		my $table = "| Network | Range |\n|:--------|:------|\n";
		for my $network (sort keys %claims) {
			$table .= sprintf("| %s | %s |\n", $network, $claims{$network});
		}
		info("%s\n", build_markdown_table($table));
	}
}

# }}}
# _display_available_section - Render free IP ranges {{{
sub _display_available_section {
	my ($subnet_data) = @_;

	my $free_size = ref($subnet_data->{free_range}) ? $subnet_data->{free_range}->size : 0;
	info("  #Gi{Free}: %d IPs", $free_size);
	if ($free_size > 0) {
		info(" (%s)\n", $subnet_data->{free_range}->range);
	} else {
		info("\n");
	}
}

# }}}
# _display_utilization_bar - Visual usage bar with counts and percentages {{{
sub _display_utilization_bar {
	my ($subnet_data) = @_;
	my $total = $subnet_data->{cidr_info}{total_addresses} || return;

	my $reserved_count  = ref($subnet_data->{reserved_range})  ? $subnet_data->{reserved_range}->size  : 0;
	my $allocated_count = ref($subnet_data->{allocated_range}) ? $subnet_data->{allocated_range}->size : 0;
	my $free_count      = ref($subnet_data->{free_range})      ? $subnet_data->{free_range}->size      : 0;

	my $bar_width = 40;
	my $r_pct = $reserved_count / $total;
	my $a_pct = $allocated_count / $total;
	my $f_pct = $free_count / $total;

	my $r_len = int($r_pct * $bar_width + 0.5);
	my $a_len = int($a_pct * $bar_width + 0.5);
	my $f_len = $bar_width - $r_len - $a_len;
	$f_len = 0 if $f_len < 0;

	my $bar = '#R{' . ('=' x $r_len) . '}'
	        . '#Y{' . ('=' x $a_len) . '}'
	        . ('.' x $f_len);

	info("  [%s] #R{R}:%d/%.0f%% #Y{A}:%d/%.0f%% #G{F}:%d/%.0f%%\n",
		$bar,
		$reserved_count, $r_pct * 100,
		$allocated_count, $a_pct * 100,
		$free_count, $f_pct * 100);
}

# }}}

# _serialize_for_json - Convert data structure for JSON output {{{
sub _serialize_for_json {
	my ($data) = @_;

	my %out = (
		env_name  => $data->{env_name},
		ocfp_type => $data->{ocfp_type},
		vpc_cidr  => $data->{vpc_cidr},
		vpc_info  => $data->{vpc_info},
		subnets   => {},
	);

	for my $name (keys %{$data->{subnets}}) {
		my $s = $data->{subnets}{$name};
		$out{subnets}{$name} = {
			cidr_block      => $s->{cidr_block},
			cidr_info       => $s->{cidr_info},
			az              => $s->{az},
			gateway         => $s->{gateway},
			dns             => $s->{dns},
			reserved_range  => ref($s->{reserved_range})  ? $s->{reserved_range}->range  : '',
			available_range => ref($s->{available_range}) ? $s->{available_range}->range : '',
			allocated_range => ref($s->{allocated_range}) ? $s->{allocated_range}->range : '',
			free_range      => ref($s->{free_range})      ? $s->{free_range}->range      : '',
			named_reserved  => $s->{named_reserved},
			claims          => $s->{claims},
		};
	}

	return \%out;
}

# }}}

1;
