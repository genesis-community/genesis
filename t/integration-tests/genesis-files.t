#!/usr/bin/env perl
use strict;
use warnings;

use lib 'lib';
use lib 't';
use helper;

use Test::More;
use Test::Exception;
use Test::Output;
use Test::Exit;
use Cwd ();

use_ok 'Genesis';

my $start_dir = Cwd::getcwd;

subtest 'fs utilities' => sub {
	my $tmp = Cwd::abs_path(workdir);

	lives_ok { mkfile_or_fail("$tmp/file", "stuff!") } "mkfile_or_fail should not fail";
	ok -f "$tmp/file", "mkfile_or_fail should make a file if it didn't fail";
	is slurp("$tmp/file"), "stuff!", "mkfile_or_fail should populate the file";

	lives_ok { mkfile_or_fail("$tmp/a/b/c", "data") } "mkfile_or_fail should not fail";
	ok -d "$tmp/a/b", "mkfile_or_fail should create intervening parent directories";

	lives_ok { copy_or_fail("$tmp/file", "$tmp/copy") } "copy_or_fail should not fail";
	ok -f "$tmp/copy", "copy_or_fail should make a file if it didn't fail";
	is slurp("$tmp/copy"), slurp("$tmp/file"), "copy_or_fail should copy the file";

	lives_ok { mkdir_or_fail("$tmp/dir") } "mkdir_or_fail should not fail";
	ok -d "$tmp/dir",  "mkdir_or_fail should make a dir if it didn't fail";

	local $ENV{GENESIS_IGNORE_EVAL}=1;

	my ($out,$err);
	($out,$err) = output_from {
		exits_nonzero {
			mkfile_or_fail("$tmp/file/not/a/dir/file", "whatevs");
		} "mkfile_or_fail should fail if it cannot succeed";
	};

	($out,$err) = output_from {
		exits_nonzero {
			copy_or_fail("$tmp/e/no/ent", "$tmp/copy2");
		} "copy_or_fail should fail if it cannot succeed";
	};

	($out,$err) = output_from {
		exits_nonzero {
			mkdir_or_fail("$tmp/file/not/a/dir");
		} "mkdir_or_fail should fail if it cannot succeed";
	};

	lives_ok { symlink_or_fail("$tmp/file", "$tmp/link"); } "symlink_or_fail shoud not fail";
	sleep 0.1; # symlink() seems to have a race condition?
	ok -l "$tmp/link", "symlink_or_fail should make a symbolic link if it didn't fail";

	($out,$err) = output_from {
		exits_nonzero {
			symlink_or_fail("$tmp/e/no/ent", "$tmp/void");
		} "symlink_or_fail should fail if it cannot succeed";
	};

	chdir $tmp;
	my $here = Cwd::getcwd;
	chdir $here; lives_ok      { chdir_or_fail("$tmp/dir"); }  "chdir_or_fail(dir) should not fail";
	chdir $here; output_from { exits_nonzero { chdir_or_fail("$tmp/file"); } "chdir_or_fail(file) should fail"; };
	chdir $here;

	pushd("$tmp/dir"); is Cwd::getcwd, "$tmp/dir", "pushd put us where we wanted to go";
	pushd("$tmp/dir"); is Cwd::getcwd, "$tmp/dir", "pushd put us where we wanted to go (again)";
	popd();            is Cwd::getcwd, "$tmp/dir", "popd put us back in the previous \$tmp/dir...";
	popd();            is Cwd::getcwd, "$here",    "popd put us back in our old cwd";

	chdir '/'; is humanize_path($ENV{HOME}.'/dir'), '~/dir', "humanize_path shows path relative to \$HOME";
	is humanize_path($ENV{HOME}.'/big/long/path/to/nonexistant.file'), '~/big/long/path/to/nonexistant.file', "humanize_path shows long path relative to \$HOME";
	chdir $here; is humanize_path($here.'/dir'), 'dir', "humanize_path shows path relative to pwd";
	qx(cp `which prove` "$here/"); is humanize_path($here.'/prove'), './prove', "humanize_path shows executable in cwd with leading './'";
	is humanize_path($here.'/big/long/../../path/to/nonexistant.file'), 'path/to/nonexistant.file', "humanize_path shows long path relative to pwd";
	is humanize_path($here.'/../diff_repo/some_file.yml'), '../diff_repo/some_file.yml', "humanize_path shows uptree path relative to pwd";
	is humanize_path($tmp), $tmp, "humanize_path shows full path when not relative to \$HOME or pwd";
};

subtest 'chmod_or_fail' => sub {
	my $tmp = Cwd::abs_path(workdir);
	mkfile_or_fail("$tmp/chmod_test", "test content");

	lives_ok { chmod_or_fail(0644, "$tmp/chmod_test") } "chmod_or_fail should not fail on valid file";
	my $mode = (stat("$tmp/chmod_test"))[2] & 0777;
	is $mode, 0644, "file mode changed to 0644";

	lives_ok { chmod_or_fail(0755, "$tmp/chmod_test") } "chmod_or_fail can change mode again";
	$mode = (stat("$tmp/chmod_test"))[2] & 0777;
	is $mode, 0755, "file mode changed to 0755";

	local $ENV{GENESIS_IGNORE_EVAL}=1;
	output_from {
		exits_nonzero {
			chmod_or_fail(0644, "$tmp/nonexistent");
		} "chmod_or_fail should fail on nonexistent file";
	};
};

subtest 'copy_tree_or_fail' => sub {
	my $tmp = Cwd::abs_path(workdir);

	# Create source tree
	mkdir_or_fail("$tmp/source/subdir");
	mkfile_or_fail("$tmp/source/file1.txt", "content1");
	mkfile_or_fail("$tmp/source/subdir/file2.txt", "content2");

	lives_ok { copy_tree_or_fail("$tmp/source", "$tmp/dest") } "copy_tree_or_fail should not fail";
	ok -d "$tmp/dest", "destination directory created";
	ok -f "$tmp/dest/file1.txt", "file1.txt copied";
	ok -f "$tmp/dest/subdir/file2.txt", "subdir/file2.txt copied";
	is slurp("$tmp/dest/file1.txt"), "content1", "file1 content correct";
	is slurp("$tmp/dest/subdir/file2.txt"), "content2", "file2 content correct";

	local $ENV{GENESIS_IGNORE_EVAL}=1;
	output_from {
		exits_nonzero {
			copy_tree_or_fail("$tmp/nonexistent", "$tmp/dest2");
		} "copy_tree_or_fail should fail on nonexistent source";
	};
};

subtest 'expand_path and absolute_path' => sub {
	my $tmp = Cwd::abs_path(workdir);

	# Tilde expansion
	local $ENV{HOME} = '/home/testuser';
	is expand_path('~/file.txt'), '/home/testuser/file.txt', 'tilde expands to HOME';
	is expand_path('~'), '/home/testuser', 'bare tilde expands to HOME';

	# Environment variable expansion
	local $ENV{TEST_DIR} = '/test/directory';
	is expand_path('$TEST_DIR/file.txt'), '/test/directory/file.txt', 'env var expansion with ${VAR}';
	is expand_path('${TEST_DIR}/file.txt'), '/test/directory/file.txt', 'env var expansion with ${VAR}';

	# Relative path expansion
	my $cwd = Cwd::getcwd();
	like expand_path('relative/path'), qr{^/}, 'relative path becomes absolute';

	# absolute_path is alias for expand_path
	is absolute_path('~/test'), expand_path('~/test'), 'absolute_path is alias for expand_path';

	# undef handling
	is expand_path(undef), undef, 'undef returns undef';
};

subtest 'humanize_bin' => sub {
	SKIP: {
		skip "humanize_bin requires GENESIS_CALLBACK_BIN", 2 unless $ENV{GENESIS_CALLBACK_BIN};

		my $result = humanize_bin();
		ok defined($result), 'humanize_bin returns defined value';
		ok length($result) > 0, 'humanize_bin returns non-empty string';
	}
};

chdir $start_dir;
done_testing;

# vim: ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1 nu
