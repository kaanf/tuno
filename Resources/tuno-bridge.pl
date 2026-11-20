#!/usr/bin/perl
# tuno-bridge.pl — part of Tuno, by Kaan Firat.
#
# Usage: tuno-bridge.pl <TunoBridge.dylib> [tuno_snapshot|tuno_stream]
#
# Runs a TunoBridge entry point inside Apple's signed perl, the host process
# MediaRemote is willing to talk to. See Sources/Bridge/TunoBridge.m.

use strict;
use warnings;
use DynaLoader;

my ($dylib, $entry) = @ARGV;
die "usage: $0 <dylib> [entry]\n" unless defined $dylib;
$entry //= 'tuno_snapshot';
die "unknown entry point '$entry'\n" unless $entry =~ /^tuno_(snapshot|stream)$/;

my $lib = DynaLoader::dl_load_file($dylib, 0)
    or die "cannot load $dylib: " . DynaLoader::dl_error() . "\n";
my $symbol = DynaLoader::dl_find_symbol($lib, $entry)
    or die "$entry not found in $dylib\n";

DynaLoader::dl_install_xsub("Tuno::$entry", $symbol)->();
