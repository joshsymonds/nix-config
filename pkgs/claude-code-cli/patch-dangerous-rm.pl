#!/usr/bin/env perl
# Let bypassPermissions mode skip Claude Code's dangerous-removal prompts
# ("Dangerous rm operation on possibly-empty variable path ..." and friends).
# Stock marks the `dangerousRemoval` circuit breaker bypassImmune, so the
# prompt fires even under --dangerously-skip-permissions, and no setting, env
# var or permission rule turns it off (the CLAUDE_CODE_DISABLE_*_RM_PROMPT
# vars each cover one narrower shape, never the variable-path one). Dev
# happens on replaceable machines; the prompt is pure friction there.
#
# One LENGTH-PRESERVING substitution in the circuit-breaker table flips
# bypassImmune, classifierRouted and autoModeDeny to false for
# dangerousRemoval. bypassImmune is what bypass mode consults; autoModeDeny
# routes bypass-mode removals into the 120s timeout dialog; classifierRouted
# only matters in auto mode and goes with them so the breaker is inert
# everywhere. 2.1.314 added waivableInBypass (true here); it is only read on
# the permission-check error fallback, together with bypassImmune, so it is
# left as is. Default/acceptEdits modes still prompt: the safetyCheck ask
# itself is untouched.
#
# Safety model (identical to patch-context-window.pl): the anchor is verified
# BEFORE any edit; on drift nothing is applied and the stock binary ships with
# a loud warning. The build never fails on drift.
use strict;
use warnings;

my $file = $ARGV[0] or die "usage: patch-dangerous-rm.pl <binary>\n";

open(my $fh, '<:raw', $file) or die "[cc-rm] open $file: $!\n";
local $/;
my $data = <$fh>;
close($fh);
my $orig_len = length($data);

my $find = 'dangerousRemoval:{bypassImmune:!0,waivableInBypass:!0,classifierRouted:!0,autoModeDeny:!0,';
my $repl = 'dangerousRemoval:{bypassImmune:!1,waivableInBypass:!0,classifierRouted:!1,autoModeDeny:!1,';

if (length($find) != length($repl)) {
    warn "[cc-rm] BUG: repl len " . length($repl) . " != find len "
        . length($find) . "; shipping stock binary\n";
    exit 0;
}

my $n = () = $data =~ /\Q$find\E/g;
if ($n != 1) {
    warn "[cc-rm] anchor found $n time(s) (expected 1); upstream likely changed "
        . "the circuit-breaker table. Applying NONE; shipping stock binary.\n";
    exit 0;
}

$n = ($data =~ s/\Q$find\E/$repl/g);
if ($n != 1 || length($data) != $orig_len) {
    warn "[cc-rm] apply replaced $n (expected 1) or changed byte length; "
        . "shipping stock binary\n";
    exit 0;
}

open(my $out, '>:raw', $file) or die "[cc-rm] open-w $file: $!\n";
print $out $data;
close($out);
print STDERR "[cc-rm] applied dangerous-removal bypass patch (byte length $orig_len preserved)\n";
exit 0;
