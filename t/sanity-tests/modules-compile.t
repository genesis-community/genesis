#!perl
use strict;
use warnings;
use Test::More;

# Get all .pm files and convert to module names
my @modules;
for my $file (glob('lib/*.pm lib/*/*.pm lib/*/*/*.pm lib/*/*/*/*.pm')) {
	my $module = $file;
	$module =~ s|^lib/||;
	$module =~ s|\.pm$||;
	$module =~ s|/|::|g;
	push @modules, $module;
}

plan tests => scalar(@modules);

for my $module (sort @modules) {
	use_ok($module) or BAIL_OUT("Cannot load $module - aborting further tests");
}

done_testing();
# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
