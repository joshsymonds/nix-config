#!/usr/bin/env perl
# Make the source patches take effect. The `claude` binary is a Bun standalone
# executable whose JS modules ship precompiled JSC bytecode beside their
# source, and Bun runs the bytecode whenever a module has some: a patch to the
# embedded source text alone is never executed (verified 2026-10-07 on 2.1.293:
# a patched --version string still printed stock until the bytecode went).
# Zeroing a module's bytecode length makes Bun compile that module from its
# source, patches included.
#
# Usage: drop-bytecode.pl <pristine> <patched>
#
# Every module whose source differs between the two binaries loses its
# bytecode in <patched>; every other module keeps it, so only the patched
# modules pay the parse cost at startup. Both binaries must share one layout
# (the patches are length-preserving and the pristine copy is taken after
# patchelf), which the script checks before editing anything.
#
# Bun 1.4 graph layout: the payload ends with "\n---- Bun! ----\n", preceded by
# a 32-byte Offsets struct whose first fields are byte_count (u64) and the
# module table's {offset, length} (u32 each); the graph starts byte_count bytes
# before that struct. Each module entry is 52 bytes: six {offset, length}
# string pointers (name, contents, sourcemap, bytecode, module_info,
# bytecode_origin_path) and four flag bytes. On any layout mismatch the script
# edits nothing and warns: the binary keeps working, the patches just stay
# inert, which is the state before this script existed.
use strict;
use warnings;

my ($pristine_path, $patched_path) = @ARGV;
die "usage: drop-bytecode.pl <pristine> <patched>\n" unless defined $patched_path;

sub slurp {
    my ($path) = @_;
    open(my $fh, '<:raw', $path) or die "[cc-bytecode] open $path: $!\n";
    local $/;
    my $data = <$fh>;
    close($fh);
    return $data;
}

my $trailer    = "\n---- Bun! ----\n";
my $entry_size = 52;

# Returns (base, module-table offset, module count), or an error string.
sub graph {
    my ($data) = @_;
    my $trailer_at = rindex($data, $trailer);
    return "no Bun trailer" if $trailer_at < 32;
    my ($byte_count) = unpack('Q<', substr($data, $trailer_at - 32, 8));
    my ($table_offset, $table_length) = unpack('V V', substr($data, $trailer_at - 24, 8));
    my $base = $trailer_at - 32 - $byte_count;
    return "graph base out of range" if $base < 0;
    return "module table out of range" if $table_offset + $table_length > $byte_count;
    return "module table length $table_length is not a multiple of $entry_size"
        if $table_length % $entry_size;
    return ($base, $base + $table_offset, $table_length / $entry_size);
}

sub skip {
    warn "[cc-bytecode] $_[0]; leaving bytecode in place, so the source patches stay inert\n";
    exit 0;
}

my $pristine = slurp($pristine_path);
my $patched  = slurp($patched_path);
skip("pristine and patched sizes differ") if length($pristine) != length($patched);
my @pristine_graph = graph($pristine);
my @patched_graph  = graph($patched);
skip($pristine_graph[0]) if @pristine_graph == 1;
skip($patched_graph[0]) if @patched_graph == 1;
skip("pristine and patched module tables differ")
    if join(',', @pristine_graph) ne join(',', @patched_graph);

my ($base, $table, $count) = @patched_graph;
my @drop;
for my $index (0 .. $count - 1) {
    my $entry = $table + $index * $entry_size;
    my @field = unpack('V12', substr($patched, $entry, 48));
    my ($contents_offset, $contents_length, $bytecode_length) = @field[2, 3, 7];
    skip("module $index points outside the graph")
        if $base + $contents_offset + $contents_length > length($patched);
    next unless $bytecode_length;
    my $start = $base + $contents_offset;
    next if substr($pristine, $start, $contents_length) eq substr($patched, $start, $contents_length);
    my ($name_offset, $name_length) = @field[0, 1];
    push @drop, [$entry, substr($patched, $base + $name_offset, $name_length)];
}

# Verify-then-apply: nothing is written unless every entry above parsed.
for my $item (@drop) {
    substr($patched, $item->[0] + 7 * 4, 4) = pack('V', 0);
}
open(my $out, '>:raw', $patched_path) or die "[cc-bytecode] open-w $patched_path: $!\n";
print $out $patched;
close($out);
print STDERR "[cc-bytecode] dropped bytecode for " . scalar(@drop) . " patched module(s): "
    . join(', ', map { $_->[1] } @drop) . "\n";
exit 0;
