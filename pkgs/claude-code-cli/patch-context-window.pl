#!/usr/bin/env perl
# Teach the bun-compiled `claude` binary the true per-model context window for
# non-Claude ("foreign") models, via three LENGTH-PRESERVING substitutions in
# the embedded JS. Bun single-file executables do not integrity-check the
# embedded script (same property the tengu_fleet_past_sessions patch relies on),
# but byte offsets must not move, so every replacement is exactly as long as
# what it replaces.
#
# Safety model (mirrors the fleet-gate warn-and-ship-stock behaviour): every
# anchor is verified BEFORE any edit is applied. If any anchor's occurrence
# count is wrong (a version bump renamed/reshuffled minified names), NONE of the
# edits are applied and the STOCK binary is shipped with a loud warning. The
# build never fails on drift — the unpatched binary still honours
# CLAUDE_CODE_MAX_CONTEXT_TOKENS natively.
use strict;
use warnings;

my $file = $ARGV[0] or die "usage: patch-context-window.pl <binary>\n";

open(my $fh, '<:raw', $file) or die "[cc-window] open $file: $!\n";
local $/;
my $data = <$fh>;
close($fh);
my $orig_len = length($data);

# A /* ... */ comment of exactly $n bytes (spaces as filler). Used to absorb the
# byte-length difference when a replacement expression is shorter than what it
# replaces, so the total clause length is preserved.
sub pad_comment {
    my ($n) = @_;
    die "[cc-window] BUG: comment pad needs >=4 bytes, got $n\n" if $n < 4;
    return "/*" . (" " x ($n - 4)) . "*/";
}

my @subs;

# S1: enable the model-capabilities subsystem (K4t gates the startup models.list
# fetch qm(), the disk-cache prime krr(), and the per-model lookup vL()). As of
# 2.1.257 flipping it also lets G5() source max_output_tokens from the same
# cache natively — a bonus over the 2.1.234 wBo gate this replaces.
push @subs, {
    name => 'S1_K4t',
    find => 'function K4t(){return!1}',
    repl => 'function K4t(){return!0}',
};

# S2: in PL (window resolution), source the per-model input window from the
# capabilities cache for non-claude ids instead of the
# CLAUDE_CODE_MAX_CONTEXT_TOKENS env var. Only the 32-byte env token becomes
# the 23-byte cache lookup vL(e)?.max_input_tokens; the 9-byte difference is
# absorbed by a /* */ comment. The existing non-claude gate kL(e) and the
# `return Eme` (200k default) fallthrough are untouched, so claude ids and
# cache misses (vL(e) -> undefined) still fall through unchanged. The full
# clause is used as the anchor because the bare token is not unique (also in
# wL and KS).
{
    my $find      = 'let d=a.CLAUDE_CODE_MAX_CONTEXT_TOKENS;if(d!==void 0&&d>0&&kL(e))return d;return Eme}';
    my $token_old = 'a.CLAUDE_CODE_MAX_CONTEXT_TOKENS';
    my $token_new = 'vL(e)?.max_input_tokens';
    my $pad       = pad_comment(length($token_old) - length($token_new));
    (my $repl = $find) =~ s/\Q$token_old\E/$token_new$pad/;
    push @subs, { name => 'S2_PL', find => $find, repl => $repl };
}

# S3: neuter the 1M-credit clamp by forcing the latch accessor to false. Body
# becomes `return!1` followed by a /* */ comment padding it to the original
# length; the original latch call is dropped entirely (no dead RHS to evaluate).
# (2.1.234's Iwr accessor is 2.1.257's eje; its only window-path caller is
# FEn(e,n){return eje()&&wL()===void 0&&PL(e,n)>jO}.)
{
    my $find   = 'function eje(){return n().host.accountCreditLatches.longContext1mCreditsBlocked()}';
    my $prefix = 'function eje(){return!1';
    my $suffix = '}';
    my $padlen = length($find) - length($prefix) - length($suffix);
    my $repl   = $prefix . pad_comment($padlen) . $suffix;
    push @subs, { name => 'S3_eje', find => $find, repl => $repl };
}

# Static invariant: every replacement is exactly as long as its find. A failure
# here is a bug in THIS script, not upstream drift; degrade to stock loudly.
for my $s (@subs) {
    if (length($s->{find}) != length($s->{repl})) {
        warn "[cc-window] BUG: $s->{name} repl len " . length($s->{repl})
            . " != find len " . length($s->{find}) . "; shipping stock binary\n";
        exit 0;
    }
}

# VERIFY-ALL-BEFORE-APPLYING-ANY: each anchor must occur exactly once.
for my $s (@subs) {
    my $n = () = $data =~ /\Q$s->{find}\E/g;
    if ($n != 1) {
        warn "[cc-window] anchor $s->{name} found $n time(s) (expected 1); "
            . "upstream likely renamed minified symbols. Applying NONE of the "
            . "context-window patches; shipping stock binary.\n";
        exit 0;
    }
}

# Apply all three. Nothing is written to disk until every check below passes, so
# an unexpected failure here still leaves the on-disk binary stock.
for my $s (@subs) {
    my $n = ($data =~ s/\Q$s->{find}\E/$s->{repl}/g);
    if ($n != 1) {
        warn "[cc-window] apply $s->{name} replaced $n (expected 1); shipping stock binary\n";
        exit 0;
    }
}

# Sanity gate (in-memory): total byte length preserved; each replacement present
# exactly once. The runnable `claude --version` check lives in the Nix
# installPhase, which restores the stock backup if the patched binary won't run.
if (length($data) != $orig_len) {
    warn "[cc-window] byte length changed ($orig_len -> " . length($data)
        . "); shipping stock binary\n";
    exit 0;
}
for my $s (@subs) {
    my $n = () = $data =~ /\Q$s->{repl}\E/g;
    if ($n != 1) {
        warn "[cc-window] post-apply $s->{name} present $n time(s) (expected 1); shipping stock binary\n";
        exit 0;
    }
}

open(my $out, '>:raw', $file) or die "[cc-window] open-w $file: $!\n";
print $out $data;
close($out);
print STDERR "[cc-window] applied 3 context-window patches (byte length $orig_len preserved)\n";
exit 0;
