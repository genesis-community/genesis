#!/usr/bin/env perl
use strict;
use warnings;
use lib 't';
use helper;

use_ok 'Genesis::Term';

subtest 'csize returns display width of colored strings' => sub {
	is(csize("hello"), 5, 'plain text returns character count');
	is(csize(""), 0, 'empty string returns 0');
	is(csize("ab"), 2, 'short string works');
	is(csize("#G{hi}"), 2, 'colored string width ignores color markup');
};

done_testing;
