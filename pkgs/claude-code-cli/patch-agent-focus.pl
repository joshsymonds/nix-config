#!/usr/bin/env perl
# Teach the bun-compiled `claude` binary to report WHICH agent's transcript
# view is focused, via two LENGTH-PRESERVING substitutions in the embedded JS
# (same framework as patch-context-window.pl). Claude renders one
# session-scoped statusline on every screen and tells the statusLine hook
# nothing about UI focus, so a custom statusline cannot show "the agent I am
# looking at". The subagentStatusLine payload builder, however, is called from
# a tick closure that has the full app state in scope — including
# viewingAgentTaskId, set on transcript-view enter and cleared on exit.
#
# F1 swaps the builder's 4th argument from the token-samples Map (whose
# payload field Steward ignores) to the app state; F2 spends the bytes of the
# two ignored per-task fields (startTime, tokenSamples) on a per-task
# `focused` boolean. Steward's subagent hook relays it through the /dev/shm
# agents-state file, and the main statusline's model chip shows the focused
# agent's model. A stock binary (this patch skipped on drift) simply never
# sets `focused`, and Steward falls back to the aggregate running-agents
# view — nothing breaks.
#
# Safety model (identical to patch-context-window.pl): every anchor is
# verified BEFORE any edit; on any drift NONE are applied and the stock binary
# ships with a loud warning. The build never fails on drift.
use strict;
use warnings;

my $file = $ARGV[0] or die "usage: patch-agent-focus.pl <binary>\n";

open(my $fh, '<:raw', $file) or die "[cc-focus] open $file: $!\n";
local $/;
my $data = <$fh>;
close($fh);
my $orig_len = length($data);

# A /* ... */ comment of exactly $n bytes (spaces as filler), absorbing the
# byte-length difference when a replacement is shorter than what it replaces.
sub pad_comment {
    my ($n) = @_;
    die "[cc-focus] BUG: comment pad needs >=4 bytes, got $n\n" if $n < 4;
    return "/*" . (" " x ($n - 4)) . "*/";
}

my @subs;

# F1: at the tick's call site, pass the app-state snapshot `Le` (already bound
# at the top of the tick as `let Le=x.getState()`) instead of the token-samples
# Map. Argument-position whitespace pads the call to identical length. The
# samples Map keeps being maintained by the tick (`nnt(Te.current, ...)`) —
# only the builder stops receiving it.
push @subs, {
    name => 'F1_int_callsite',
    find => 'int(Oe,Math.max(0,ue-jh()-TP),ct,Te.current).then',
    repl => 'int(Oe,Math.max(0,ue-jh()-TP),ct,Le        ).then',
};

# F2: in the builder's per-task map, drop the two fields Steward ignores
# (startTime, tokenSamples — the latter being the only use of the old 4th
# parameter) and spend their 53 bytes on `focused:tt.id===z.viewingAgentTaskId`
# plus a pad comment. With F1 applied, `z` is the app state; on a task list
# where no agent view is open, viewingAgentTaskId is undefined and every
# task's focused is false.
{
    my $find = 'startTime:tt.startTime,model:tt.model,effort:tt.effort,'
        . 'contextWindowSize:tt.model?Nf(tt.model,Jf()):void 0,'
        . 'tokenCount:tt.progress?.tokenCount??0,tokenSamples:z.get(tt.id)??[],'
        . 'cwd:tt.cwd??ue}';
    my $core = 'model:tt.model,effort:tt.effort,'
        . 'contextWindowSize:tt.model?Nf(tt.model,Jf()):void 0,'
        . 'tokenCount:tt.progress?.tokenCount??0,focused:tt.id===z.viewingAgentTaskId,';
    my $tail   = 'cwd:tt.cwd??ue}';
    my $padlen = length($find) - length($core) - length($tail);
    push @subs, {
        name => 'F2_int_tasks',
        find => $find,
        repl => $core . pad_comment($padlen) . $tail,
    };
}

# Static invariant: every replacement is exactly as long as its find. A
# failure here is a bug in THIS script, not upstream drift; degrade to stock.
for my $s (@subs) {
    if (length($s->{find}) != length($s->{repl})) {
        warn "[cc-focus] BUG: $s->{name} repl len " . length($s->{repl})
            . " != find len " . length($s->{find}) . "; shipping stock binary\n";
        exit 0;
    }
}

# VERIFY-ALL-BEFORE-APPLYING-ANY: each anchor must occur exactly once.
for my $s (@subs) {
    my $n = () = $data =~ /\Q$s->{find}\E/g;
    if ($n != 1) {
        warn "[cc-focus] anchor $s->{name} found $n time(s) (expected 1); "
            . "upstream likely renamed minified symbols. Applying NONE of the "
            . "agent-focus patches; shipping stock binary.\n";
        exit 0;
    }
}

for my $s (@subs) {
    my $n = ($data =~ s/\Q$s->{find}\E/$s->{repl}/g);
    if ($n != 1) {
        warn "[cc-focus] apply $s->{name} replaced $n (expected 1); shipping stock binary\n";
        exit 0;
    }
}

if (length($data) != $orig_len) {
    warn "[cc-focus] byte length changed ($orig_len -> " . length($data)
        . "); shipping stock binary\n";
    exit 0;
}
for my $s (@subs) {
    my $n = () = $data =~ /\Q$s->{repl}\E/g;
    if ($n != 1) {
        warn "[cc-focus] post-apply $s->{name} present $n time(s) (expected 1); shipping stock binary\n";
        exit 0;
    }
}

open(my $out, '>:raw', $file) or die "[cc-focus] open-w $file: $!\n";
print $out $data;
close($out);
print STDERR "[cc-focus] applied 2 agent-focus patches (byte length $orig_len preserved)\n";
exit 0;
