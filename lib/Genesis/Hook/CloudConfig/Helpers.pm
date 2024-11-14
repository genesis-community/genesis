package Genesis::Hook::CloudConfig::Helpers;
use strict;
use warnings;

use Genesis;

use base 'Exporter';
our @EXPORT = qw/gigabytes megabytes/;

sub megabytes { return shift(); } # for uniformity
sub gigabytes { return shift() * 1024; }

1;
