#!/usr/bin/env perl

use Getopt::Long;
use Pod::Usage;

use strict;
use warnings;

my $xmfa_file;
my $print_seq_ids;
my $enable_sort = 0;
my $enable_invalid_gap_filter = 1;
my $invalid_gap_min_pct_id = 0.7;
my $invalid_gap_max_gap_pct = 0.05;
my @sort_order = ();
my @includes = ();
my %includes = ();
my $fasta_dir = '.';
my $fasta_postfix = '.sort.gapped.fa';
my $fasta_linker;
my $coords_file;
my $output_xmfa_file;
my $gfa_file;
my $use_seq_names = 1;
my $gfa_postfix;
my $vg_path;
my $threads = 1;
my $null_record = 'NA';
my $wrap_len = 80;
my $help;

my %block_seq_order = ();
my %block_seq_sort_priorities = ();
my %block_seqs = ();
my %block_lens = ();
my %block_starts = ();
my %block_stops = ();
my %block_seq_info = ();
my @block_order = ();
my %unplaced_blocks = ();
my %seq_names = ();
my %seq_id_files = ();
my %seq_id_fasta_fhs = ();
my %gfa_paths = ();
my %gfa_path_blocks = ();
my $gfa_offset = 0;
my $gfa_overlap;
my $vg_rand = sprintf("%06d", int(rand(999999)));
my $vg_tmp_dir = "vg.tmp.$vg_rand";

parse_args();
parse_xmfa_header();
my ($coords_fh, $output_xmfa_fh, $gfa_fh) = open_fhs();
parse_blocks();

if ($enable_invalid_gap_filter == 1) {
	filter_invalid_gaps();
}

if ($enable_sort == 1) {
	set_sort_priorities();
	orient_blocks();
	sort_blocks();
	orient_adj_inversions();
}

else {
	foreach my $block_id (keys %block_seqs) {
		push(@block_order, $block_id);
	}
}

print_blocks();

exit(0);


sub sort_blocks {
	foreach my $block_id (keys %block_seqs) {
		$unplaced_blocks{$block_id}++;
	}

	foreach my $seq_id (@sort_order) {
		if ($seq_id == $sort_order[0]) {
			foreach my $block_start (sort { $a <=> $b } keys %{$block_starts{$seq_id}}) {
				my $block_id = $block_starts{$seq_id}{$block_start};

				if (! exists($unplaced_blocks{$block_id})) {
					next();
				}

				if (! @block_order) {
					push(@block_order, $block_id);
					delete($unplaced_blocks{$block_id});

					next();
				}

				my $last_seq_id_index;

				foreach my $index (0..$#block_order) {
					my $index_block_id = $block_order[$index];

					if (! exists($block_seq_info{$index_block_id}{$seq_id}{'start'})) {
						next();
					}

					my $index_seq_start = $block_seq_info{$index_block_id}{$seq_id}{'start'};

					$last_seq_id_index = $index;

					if ($block_start < $index_seq_start) {
						splice(@block_order, $index, 0, $block_id);
						delete($unplaced_blocks{$block_id});

						last();
					}
				}

				if (exists($unplaced_blocks{$block_id}) && defined($last_seq_id_index)) {
					splice(@block_order, $last_seq_id_index + 1, 0, $block_id);
					delete($unplaced_blocks{$block_id});

					next();
				}
			}
		}

		else {
			my @static_block_order = @block_order;

			foreach my $block_id (@static_block_order) {
				my $unplaced_block_count = keys %unplaced_blocks;

				if ($unplaced_block_count == 0) {
					last();
				}

				my $block_order_index = get_block_order_index($block_id);

				extend_block($block_id, $seq_id, 'left');

				$block_order_index = get_block_order_index($block_id);

				extend_block($block_id, $seq_id, 'right');
			}
		}
	}

	return(0);
}


sub print_blocks {
	my %fasta_seq = ();
	my %fasta_pos = ();

	my $block_count = 1;

	if (defined($coords_file)) {
		print($coords_fh join("\t", '#sort_block_pos', 'orig_block_pos', 'block_len'));

		foreach my $seq_id (@sort_order) {
			if (@includes && ! exists($includes{$seq_id})) {
				next();
			}

			my $seq_name = $seq_names{$seq_id};

			print($coords_fh join("\t", '', "$seq_name.fasta.start", "$seq_name.fasta.stop", "$seq_name.xmfa.start", "$seq_name.xmfa.stop", "$seq_name.xmfa.strand"));
		}

		print($coords_fh "\n");
	}

	if (defined($gfa_file)) {
		print($gfa_fh "H\tVN:Z:1.0\n");

		if (-e $vg_tmp_dir) {
			foreach my $block_file (glob("$vg_tmp_dir/block*")) {
				unlink($block_file);
			}
		}

		mkdir($vg_tmp_dir);
	}

	# mauve viewer compatibility
	if (defined($output_xmfa_file)) {
		foreach my $seq_id (sort { $a <=> $b } keys %seq_id_files) {
			print($output_xmfa_fh "> ${seq_id}:0-0 + $seq_id_files{$seq_id}\n-\n");
		}

		print($output_xmfa_fh "=\n");
	}

	foreach my $block_id (@block_order) {
		my $block_len = $block_lens{$block_id};

		if (defined($coords_file)) {
			print($coords_fh "$block_count\t$block_id\t$block_len");
		}

		my $block_fasta_fh;
		my $block_file_prefix = "$vg_tmp_dir/block$block_id";
		my $block_fasta_file = "$block_file_prefix.fa";
		my $gfa_seq_count = 0;

		if (defined($gfa_file)) {
            open($block_fasta_fh, '>', $block_fasta_file) or error("can't open block fasta file: $!");
        }


		foreach my $seq_id (@sort_order) {
			if (@includes && ! exists($includes{$seq_id})) {
				next();
			}

			my $xmfa_start = $null_record;
			my $xmfa_stop = $null_record;
			my $xmfa_strand = $null_record;
			my $seq;
			my $seq_len = 0;

			if (exists($block_seqs{$block_id}{$seq_id})) {
				$xmfa_start = $block_seq_info{$block_id}{$seq_id}{'start'};
				$xmfa_stop = $block_seq_info{$block_id}{$seq_id}{'stop'};
				$xmfa_strand = $block_seq_info{$block_id}{$seq_id}{'strand'};
				$seq_len = abs($xmfa_stop - $xmfa_start) + 1;

				if ($xmfa_start == 0 && $xmfa_stop == 0) {
					$seq_len = 0;
				}

				$seq = $block_seqs{$block_id}{$seq_id};
				$seq =~ s/\n//g;
			}

			else {
				$seq = '-' x $block_len;
			}

			$fasta_seq{$seq_id} .= "$seq";

			if (defined($gfa_file) && $seq_len > 0) {
				my $header = ">$seq_id:$xmfa_start-$xmfa_stop:$xmfa_strand";
				my $wrapped_seq = $seq;

				$wrapped_seq =~ s/[^acgtnACGTN-]/N/g;
				$wrapped_seq =~ s/.{$wrap_len}\K/\n/g;

				chomp($wrapped_seq);

				print($block_fasta_fh "$header\n$wrapped_seq\n");

				$gfa_path_blocks{$seq_id}{$xmfa_start} = $block_id;
				$gfa_seq_count++;
			}

			if (defined($coords_file)) {
				if (! exists($fasta_pos{$seq_id})) {
					$fasta_pos{$seq_id} = 0;
				}

				my $fasta_start = $null_record;
				my $fasta_stop = $null_record;

				if ($seq_len > 0) {
					$fasta_start = $fasta_pos{$seq_id} + 1;
					$fasta_stop = $fasta_start + $seq_len - 1;
					$fasta_pos{$seq_id} = $fasta_stop;
				}

				if (defined($fasta_linker)) {
					$fasta_seq{$seq_id} .= "$fasta_linker";
					$fasta_pos{$seq_id} += length($fasta_linker);
				}

				print($coords_fh join("\t", '', $fasta_start, $fasta_stop, $xmfa_start, $xmfa_stop, $xmfa_strand));
			}
		}

		if (defined($output_xmfa_file)) {
			my $block_seq_count = 0;

			foreach my $block_seq_index (sort { $a <=> $b } keys %{$block_seq_order{$block_id}}) {
				my $seq_id = $block_seq_order{$block_id}{$block_seq_index};

				if (@includes && ! exists($includes{$seq_id})) {
					next();
				}
			
				my $header = $block_seq_info{$block_id}{$seq_id}{'header'};
				my $seq = $block_seqs{$block_id}{$seq_id};

				$seq =~ s/.{$wrap_len}\K/\n/g;

				chomp($seq);

				print($output_xmfa_fh "$header\n$seq\n");
				$block_seq_count++;
			}

			if ($block_seq_count > 0) {
				print($output_xmfa_fh "=\n");
			}
		}

		if (defined($coords_file)) {
			print($coords_fh "\n");
		}

		if (defined($gfa_file)) {
			close($block_fasta_fh);

			if ($gfa_seq_count > 0) {
				proc_gfa_block($block_file_prefix);
			}
		}

		$block_count++;
	}

	if (defined($coords_file)) {
		foreach my $seq_id (keys %seq_id_fasta_fhs) {
			my $fasta_fh = $seq_id_fasta_fhs{$seq_id};
			my $wrapped_seq = $fasta_seq{$seq_id};

			$wrapped_seq =~ s/.{$wrap_len}\K/\n/g;

			chomp($wrapped_seq);

			print($fasta_fh "$wrapped_seq");

			close($fasta_fh);
		}
	}

	if (defined($gfa_file)) {
		my %links = ();

		foreach my $seq_id (@sort_order) {
			my $prev_id;
			my $prev_strand;
			my @segs = ();
			my @overlaps = ();
			my $link_overlap = '0M';

			if (defined($gfa_overlap) && $gfa_overlap eq '*') {
				$link_overlap = '*';
			}

			if (@includes && ! exists($includes{$seq_id})) {
				next();
			}

			foreach my $start (sort { $a <=> $b } keys %{$gfa_paths{$seq_id}}) {
				my $path_rec = $gfa_paths{$seq_id}{$start};
				my ($rec_type, $header, $segs, $overlaps) = split(/\t/, $path_rec);

				push(@segs, $segs);
				push(@overlaps, $overlaps);

				my @segs = split(',', $segs);

				foreach my $seg (@segs) {
					if ($seg =~ /^(\d+)([\+\-])/) {
						my ($id, $strand) = ($1, $2);

						if (! defined($id) || ! defined($strand)) {
							print(STDOUT "id/strand not defined in seg: $seg\n");

							next();
						}
			
						if (defined($prev_id)) {
							if (! exists($links{"$prev_id $prev_strand $id $strand"})) {
								print($gfa_fh join("\t", 'L', $prev_id, $prev_strand, $id, $strand, $link_overlap), "\n");
							}

							$links{"$prev_id $prev_strand $id $strand"}++;
						}

						$prev_id = $id;
						$prev_strand = $strand;
					}
				}
			}

			if (defined($gfa_overlap) && $gfa_overlap eq '*') {
				undef(@overlaps);

				push(@overlaps, '*');
			}

			print($gfa_fh "P\t$seq_names{$seq_id}\t", join(',', @segs), "\t", join(',', @overlaps), "\n");
		}

		foreach my $vg_tmp_file (glob("$vg_tmp_dir/block*")) {
			unlink($vg_tmp_file);
		}

		rmdir($vg_tmp_dir);
	}

	return(0);
}


sub extend_block {
	my $block_id = shift();
	my $seq_id = shift();
	my $dir = shift();

	if (! defined($block_id) || ! defined($seq_id) || ! defined($dir)) {
		return(0);
	}

	my $start = $block_seq_info{$block_id}{$seq_id}{'start'};
	my $stop = $block_seq_info{$block_id}{$seq_id}{'stop'};

	if (! defined($start) || ! defined($stop)) {
		return(0);
	}

	foreach my $unplaced_block_id (keys %unplaced_blocks) {
		my $unplaced_start = $block_seq_info{$unplaced_block_id}{$seq_id}{'start'};
		my $unplaced_stop = $block_seq_info{$unplaced_block_id}{$seq_id}{'stop'};

		if (! defined($unplaced_start) || ! defined($unplaced_stop)) {
			next();
		}

		my $match = 0;

		if ($dir eq 'left') {
			if ($unplaced_stop == $start - 1) {
				my $block_order_index = get_block_order_index($block_id);

				splice(@block_order, $block_order_index, 0, $unplaced_block_id);
				delete($unplaced_blocks{$unplaced_block_id});
				$match = 1;

				extend_block($unplaced_block_id, $seq_id, $dir);
			}
		}

		elsif ($dir eq 'right') {
			if ($unplaced_start == $stop + 1) {
				my $block_order_index = get_block_order_index($block_id);

				splice(@block_order, $block_order_index + 1, 0, $unplaced_block_id);
				delete($unplaced_blocks{$unplaced_block_id});
				$match = 1;

				extend_block($unplaced_block_id, $seq_id, $dir);
			}
		}

		if ($match == 1) {
			last();
		}
	}

	return(0);
}


sub get_block_order_index {
	my $block_id = shift();

	foreach my $index (0..$#block_order) {
		if ($block_order[$index] == $block_id) {
			return($index);
		}
	}

	return(undef);
}


sub parse_blocks {
	open(XMFA, '<', $xmfa_file) or error("can't open xmfa file: $!");

	my $block_id = 1;
	my $valid_seq = 0;
	my $block_seq_count = 0;
	my $seq_id;
	my $pos;
	my $seq;

	while (my $line = <XMFA>) {
		chomp($line);

		if ($line =~ /^#/) {
			if (defined($output_xmfa_file)) {
				print($output_xmfa_fh "$line\n");
			}
		}

		elsif ($line =~ /^\>/) {
			my $mod_line = $line;

			$mod_line =~ s/^>\s*//;

			my ($seq_id_pos, $strand, $seq_file) = split(/\s+/, $mod_line);
			($seq_id, $pos) = split(':', $seq_id_pos);
			my ($start, $stop) = split('-', $pos);

			$valid_seq = 0;
			$seq = '';

			if (defined($seq_id) && defined($start) && defined($stop) && defined($strand)) {
				$block_seq_count++;
				$block_starts{$seq_id}{$start} = $block_id;
				$block_stops{$seq_id}{$stop} = $block_id;
				$block_seq_info{$block_id}{$seq_id}{'start'} = $start;
				$block_seq_info{$block_id}{$seq_id}{'stop'} = $stop;
				$block_seq_info{$block_id}{$seq_id}{'strand'} = $strand;
				$block_seq_info{$block_id}{$seq_id}{'header'} = $line;
				$block_seq_order{$block_id}{$block_seq_count} = $seq_id;

				$valid_seq = 1;
			}
		}

		elsif ($line =~ /^\=/) {
			$block_seq_count = 0;
			$block_lens{$block_id} = length($seq);
			$block_id++;
		}

		else {
			if ($valid_seq == 1) {
				$seq .= "$line";
				$block_seqs{$block_id}{$seq_id} .= "$line";
			}
		}
	}

	close(XMFA);

	return(0);
}


sub filter_invalid_gaps {
	my $invalid_gap_count = 0;
	my $invalid_gap_cols = 0;

	foreach my $block_id (sort { $a <=> $b } keys %block_seqs) {
		my %gap_info = ();
		my %gap_starts = ();
		my %gap_stops = ();
		my %max_gap_ids = ();

		my $block_len = $block_lens{$block_id};
		my $block_seq_count = 0;
		my $first_seq_id;

		foreach my $seq_id (sort { $a <=> $b } keys %{$block_seqs{$block_id}}) {
			if (! defined($first_seq_id)) {
				$first_seq_id = $seq_id;
			}

			my @col_bases = split('', $block_seqs{$block_id}{$seq_id});

			my $gap_id = 0;
			my $gap_start;
			my $last_col_index;

			foreach my $col_index (0..$#col_bases) {
				my $col_base = $col_bases[$col_index];

				if ($col_base ne '-') {
					if (defined($gap_start)) {
						my $gap_len = $col_index - $gap_start;

						$gap_info{$seq_id}{$gap_id}{'len'} = $gap_len;
						$gap_info{$seq_id}{$gap_id}{'start'} = $gap_start;
						$gap_info{$seq_id}{$gap_id}{'stop'} = $col_index - 1;
						$gap_starts{$seq_id}{$gap_start} = $gap_id;
						$gap_stops{$seq_id}{$col_index} = $gap_id;

						$gap_id++;
						$gap_start = undef;
					}
				}

				else {
					if (! defined($gap_start)) {
						$gap_start = $col_index;
					}
				}

				$last_col_index = $col_index;
			}

			if (defined($gap_start)) {
				my $gap_len = $last_col_index - $gap_start + 1;

				$gap_info{$seq_id}{$gap_id}{'len'} = $gap_len;
				$gap_info{$seq_id}{$gap_id}{'start'} = $gap_start;
				$gap_info{$seq_id}{$gap_id}{'stop'} = $last_col_index;
				$gap_starts{$seq_id}{$gap_start} = $gap_id;
				$gap_stops{$seq_id}{$last_col_index} = $gap_id;
			}

			$max_gap_ids{$seq_id} = $gap_id;
			$block_seq_count++;
		}

		foreach my $first_seq_gap_id (reverse sort { $a <=> $b } keys %{$gap_info{$first_seq_id}}) {
			my $gap_len = $gap_info{$first_seq_id}{$first_seq_gap_id}{'len'};
			my $gap_start = $gap_info{$first_seq_id}{$first_seq_gap_id}{'start'};
			my $gap_stop = $gap_info{$first_seq_id}{$first_seq_gap_id}{'stop'};
			my $gap_min = $gap_start;
			my $gap_max = $gap_stop;
			my %nested_gap_check_seq_ids = ();
			my %non_nested_gap_seq_ids = ();
			my %gap_seq_ids = ();
			my @check_col_pos = ();
			my $gap_seq_count = 1;

			$gap_seq_ids{$first_seq_id} = $first_seq_gap_id;

			push(@check_col_pos, $gap_start, $gap_start - 1, $gap_stop + 1);

			foreach my $col_index (@check_col_pos) {
				if ($gap_seq_count == $block_seq_count) {
					next();
				}   
                    
				foreach my $seq_id (sort { $a <=> $b } keys %{$block_seqs{$block_id}}) {
					if (exists($gap_seq_ids{$seq_id})) {
						next();
					}

					my $seq_gap_id;

					if (exists($gap_starts{$seq_id}{$col_index})) {
						$seq_gap_id = $gap_starts{$seq_id}{$col_index};

						if ($gap_info{$seq_id}{$seq_gap_id}{'len'} > $gap_len) {
							$nested_gap_check_seq_ids{$seq_id}++;

							next();
						}

						else {
							my $test_gap_stop = $gap_info{$seq_id}{$seq_gap_id}{'stop'};
							$non_nested_gap_seq_ids{$seq_id} = $seq_gap_id;

							if ($test_gap_stop > $gap_max) {
								$gap_max = $test_gap_stop;
							}
						}
					}

					elsif (exists($gap_stops{$seq_id}{$col_index})) {
						$seq_gap_id = $gap_stops{$seq_id}{$col_index};

						if ($gap_info{$seq_id}{$seq_gap_id}{'len'} > $gap_len) {
							$nested_gap_check_seq_ids{$seq_id}++;

							next();
						}

						else {
							my $test_gap_start = $gap_info{$seq_id}{$seq_gap_id}{'start'};
							$non_nested_gap_seq_ids{$seq_id} = $seq_gap_id;

							if ($test_gap_start < $gap_min) {
								$gap_min = $test_gap_start;
							}
						}
					}

					else {
						$nested_gap_check_seq_ids{$seq_id}++;
					}

					if (! defined($seq_gap_id)) {
						next();
					}

					my $seq_gap_len = $gap_info{$seq_id}{$seq_gap_id}{'len'};

					if ($seq_gap_len != $gap_len) {
						# gaps must be same length
						next();
					}

					$gap_seq_ids{$seq_id} = $seq_gap_id;
					$gap_seq_count++;
				}
			}

			# gaps found on both sides of first seq gap
			if ($gap_min < $gap_start && $gap_max > $gap_stop) {
				next();
			}

			# check for nested gaps
			if ($gap_seq_count > 1) {
				foreach my $seq_id (keys %nested_gap_check_seq_ids) {
					my $count = $nested_gap_check_seq_ids{$seq_id};

					if ($count < 3) {
						next();
					}

					foreach my $start_col (keys %{$gap_starts{$seq_id}}) {
						if ($start_col <= $gap_min) {
							my $gap_id = $gap_starts{$seq_id}{$start_col};
							my $stop_col = $gap_info{$seq_id}{$gap_id}{'stop'};

							if ($stop_col >= $gap_max) {
								my $new_gap_id = $max_gap_ids{$seq_id} + 1;
								$max_gap_ids{$seq_id} = $new_gap_id;
								$gap_info{$seq_id}{$new_gap_id}{'start'} = $gap_start;
								$gap_info{$seq_id}{$new_gap_id}{'stop'} = $gap_stop;
								$gap_info{$seq_id}{$new_gap_id}{'len'} = $gap_len;
								$gap_seq_ids{$seq_id} = $new_gap_id;
								$gap_seq_count++;
							}
						}
					}
				}
			}

			if ($gap_seq_count != $block_seq_count) {
				next();
			}


			# check seq id adjacent to invalid gaps
			my $first_seq_start;

			if ($gap_start == $gap_min) {
				$first_seq_start = $gap_stop + 1;
			}

			else {
				$first_seq_start = $gap_start - $gap_len;
			}


			my $first_seq = substr($block_seqs{$block_id}{$first_seq_id}, $first_seq_start, $gap_len);
			my @first_seqs = split('', $first_seq);
			my $fail_seq_id = 0;

			foreach my $seq_id (keys %non_nested_gap_seq_ids) {
				my $test_gap_id = $non_nested_gap_seq_ids{$seq_id};
				my $test_gap_start = $gap_info{$seq_id}{$test_gap_id}{'start'};
				my $test_gap_stop = $gap_info{$seq_id}{$test_gap_id}{'stop'};
				my $test_seq_start;

				if ($test_gap_start == $gap_min) {
					$test_seq_start = $test_gap_stop + 1;
				}

				else {
					$test_seq_start = $test_gap_start - $gap_len;
				}

				my $test_seq = substr($block_seqs{$block_id}{$seq_id}, $test_seq_start, $gap_len);
				my $test_seq_gaps = () = $test_seq =~ /-/g;
				my $test_seq_gap_pct = $test_seq_gaps / length($test_seq);
				
				if ($test_seq_gap_pct > $invalid_gap_max_gap_pct) {
					$fail_seq_id = 1;

					last();
				}

				my @test_seqs = split('', $test_seq);
				my $mismatches = 0;

				foreach my $index (0..$#first_seqs) {
					if ($first_seqs[$index] ne $test_seqs[$index]) {
						$mismatches++;
					}
				}

				my $test_seq_pct_id = ($gap_len - $mismatches) / $gap_len;

				if ($test_seq_pct_id < $invalid_gap_min_pct_id) {
					$fail_seq_id = 1;

					last();
				}
			}

			if ($fail_seq_id == 1) {
				next();
			}


			foreach my $seq_id (sort keys %gap_seq_ids) {
				my $gap_id = $gap_seq_ids{$seq_id};
				my $start = $gap_info{$seq_id}{$gap_id}{'start'};
				my $stop = $gap_info{$seq_id}{$gap_id}{'stop'};
				my $len = $gap_info{$seq_id}{$gap_id}{'len'};

				substr($block_seqs{$block_id}{$seq_id}, $start, $len, '');
			}

			$invalid_gap_count++;
			$invalid_gap_cols += $gap_len;

			#print(STDERR "invalid gap found and corrected in block: $block_id\tgap column length: $gap_len\n");
		}
	}

	print(STDERR "invalid gaps corrected: $invalid_gap_count\n");
	print(STDERR "invalid gap MSA columns corrected: $invalid_gap_cols\n");

	return(0);
}


sub set_sort_priorities {
	foreach my $block_id (keys %block_seqs) {
		my $sort_priority = 1;

		foreach my $seq_id (@sort_order) {
			if (exists $block_seq_info{$block_id}{$seq_id}{'start'}) {
				$block_seq_sort_priorities{$block_id}{$seq_id} = $sort_priority;
				$sort_priority++;
			}
		}
	}

	return(0);
}


sub orient_blocks {
	foreach my $block_id (keys %block_seqs) {
		foreach my $seq_id (@sort_order) {
			if (exists $block_seq_info{$block_id}{$seq_id}{'strand'}) {
				if ($block_seq_info{$block_id}{$seq_id}{'strand'} eq '-') {
					rev_comp_block($block_id);
				}

				last();
			}
		}
	}

	return(0);
}


sub orient_adj_inversions {
	my %prev_seq_block = ();

	foreach my $block_index (0..$#block_order) {
		my $block_id = $block_order[$block_index];

		foreach my $seq_id (reverse @sort_order) {
			if (! exists($block_seq_info{$block_id}{$seq_id}{'start'})) {
				next();
			}

			my $sort_priority = $block_seq_sort_priorities{$block_id}{$seq_id};
			my $start = $block_seq_info{$block_id}{$seq_id}{'start'};
			my $stop = $block_seq_info{$block_id}{$seq_id}{'stop'};
			my $strand = $block_seq_info{$block_id}{$seq_id}{'strand'};

			my $move_prev_block_index;
			my $move_prev_block_id;

			if (exists($prev_seq_block{$seq_id})) {
				my $prev_block_id = $prev_seq_block{$seq_id};
				my $prev_sort_priority = $block_seq_sort_priorities{$prev_block_id}{$seq_id};

				if ($prev_sort_priority == 1) {
					my $prev_strand = $block_seq_info{$prev_block_id}{$seq_id}{'strand'};

					if ($strand ne $prev_strand) {
						my $prev_stop = $block_seq_info{$prev_block_id}{$seq_id}{'stop'};

						if ($start == ($prev_stop + 1)) {
							$move_prev_block_id = $prev_block_id;
							$move_prev_block_index = get_block_order_index($prev_block_id);
						}
					}
				}

				my $move_next_block_index;
				my $move_next_block_id;

				foreach my $next_block_index (($block_index + 1)..$#block_order) {
					my $next_block_id = $block_order[$next_block_index];

					if (! exists($block_seq_info{$next_block_id}{$seq_id}{'start'})) {
						next();
					}

					my $next_sort_priority = $block_seq_sort_priorities{$next_block_id}{$seq_id};

					if ($next_sort_priority == 1) {
						my $next_start = $block_seq_info{$next_block_id}{$seq_id}{'start'};
						my $next_strand = $block_seq_info{$next_block_id}{$seq_id}{'strand'};

						if ($strand ne $next_strand) {
							if (($stop + 1) == $next_start) {
								$move_next_block_id = $next_block_id;
								$move_next_block_index = get_block_order_index($next_block_id);
							}
						}
					}

					last();
				}

				if (defined($move_prev_block_index) || defined($move_next_block_index)) {
					foreach my $mod_block_id ($move_prev_block_id, $move_next_block_id) {
						if (defined($mod_block_id)) {
							rev_comp_block($mod_block_id);
						}
					}

					if (defined($move_prev_block_index) && defined($move_next_block_index)) {
						$block_order[$move_prev_block_index] = $move_next_block_id;
						$block_order[$move_next_block_index] = $move_prev_block_id;
					}

					elsif (defined($move_prev_block_index)) {
						splice(@block_order, $block_index + 1, 0, $move_prev_block_id);
						splice(@block_order, $move_prev_block_index, 1);
					}

					elsif (defined($move_next_block_index)) {
						splice(@block_order, $move_next_block_index, 1);
						splice(@block_order, $block_index, 0, $move_next_block_id);
					}
				}
			}

			$prev_seq_block{$seq_id} = $block_id;
		}
	}

	return(0);
}


sub rev_comp_block {
	my $block_id = shift();

	if (! defined($block_id)) {
		print(STDOUT "block id not defined in call to rev_comp_block()\n");

		return(1);
	}

	foreach my $seq_id (keys %{$block_seqs{$block_id}}) {
		my $seq = $block_seqs{$block_id}{$seq_id};
		my $rc_seq = reverse($seq);

		$rc_seq =~ tr/ACGTacgt/TGCAtgca/;

		$block_seqs{$block_id}{$seq_id} = $rc_seq;

		if ($block_seq_info{$block_id}{$seq_id}{'strand'} eq '+') {
			$block_seq_info{$block_id}{$seq_id}{'strand'} = '-';
			$block_seq_info{$block_id}{$seq_id}{'header'} =~ s/ \+ / - /;
		}

		else {
			$block_seq_info{$block_id}{$seq_id}{'strand'} = '+';
			$block_seq_info{$block_id}{$seq_id}{'header'} =~ s/ \- / + /;
		}
	}

	return(0);
}


sub proc_gfa_block {
	my $block_file_prefix = shift();

	my $block_fasta_file = "$block_file_prefix.fa";

	if (! defined($block_fasta_file) || ! -e $block_fasta_file) {
		print(STDOUT "block fasta file not defined or does not exist in proc_gfa_block()\n");

		return(1);
	}

	my $cmd = "$vg_path construct -t $threads -M $block_fasta_file 2> $block_file_prefix.vg.construct.stderr | $vg_path ids -i $gfa_offset - | $vg_path view --threads $threads - > $block_file_prefix.gfa 2> $block_file_prefix.vg.view.stderr";

	system($cmd);


	open(GFA, '<', "$block_file_prefix.gfa") or error("can't open gfa file: $!");

	while (my $line = <GFA>) {
		chomp($line);

		if ($line =~ /^S\t/) {
			my ($rec_type, $id, $seq) = split(/\t/, $line);

			if ($id > $gfa_offset) {
				$gfa_offset = $id;
			}

			print($gfa_fh "$line\n");
		}

		elsif ($line =~ /^P\t/) {
			my ($rec_type, $header, $segs, $overlaps) = split(/\t/, $line);
			my ($seq_id, $start_stop, $strand) = split(':', $header);
			my ($start, $stop) = split('-', $start_stop);

			if ($start eq $null_record || $stop eq $null_record || $strand eq $null_record) {
				next();
			}

			if ($segs eq '' || $overlaps eq '') {
				next();
			}

			if (! defined($gfa_overlap)) {
				if ($overlaps eq '*') {
					$gfa_overlap = '*';
				}
			}

			if ($strand eq '-') {
				$segs =~ tr/\+\-/-+/;

				my @segs = reverse(split(',', $segs));
				my @overlaps = reverse(split(',', $overlaps));

				$segs = join(',', @segs);
				$overlaps = join(',', @overlaps);
			}

			my $path_name = $seq_names{$seq_id};

			if (defined($gfa_postfix)) {
				$path_name .= "$gfa_postfix";
			}

			$gfa_paths{$seq_id}{$start} = join("\t", $rec_type, $path_name, $segs, $overlaps);
		}
	}

	close(GFA);

	# head node id == 1
	$gfa_offset--;

	return(0);
}


sub open_fhs {
	my $coords_fh;
	my $output_xmfa_fh;
	my $gfa_fh;

	if (defined($coords_file)) {
		open($coords_fh, '>', $coords_file) or error("can't open coords file: $!");
	}

	if (defined($output_xmfa_file)) {
		open($output_xmfa_fh, '>', $output_xmfa_file) or error("can't open output xmfa file: $!");
	}

	if (defined($gfa_file)) {
		open($gfa_fh, '>', $gfa_file) or error("can't open gfa file: $!");
	}

	return($coords_fh, $output_xmfa_fh, $gfa_fh);
}


sub parse_xmfa_header {
	my %header_seq_ids = ();
	my %base_names = ();
	my %seq_base_names = ();

	open(XMFA, '<', $xmfa_file) or error("can't open xmfa file: $!");

	while (my $line = <XMFA>) {
		if ($line =~ /^#Sequence(\d+)File/) {
			chomp($line);

			my $seq_id = $1;

			$header_seq_ids{$seq_id}++;

			my ($header_field, $header_val) = split(/\t/, $line);
			my $base_name = $header_val;

			$base_name =~ s/^.*\///;
			$base_name =~ s/\.f[ast]*a//;
			$base_name =~ s/\s+/_/g;

			if ($use_seq_names == 1 && exists($base_names{$base_name})) {
				print(STDOUT "duplicate base name: $base_name found, use of base names in output disabled\n");

				$use_seq_names = 0;
			}

			$base_names{$base_name}++;
			$seq_base_names{$seq_id} = $base_name;
			$seq_id_files{$seq_id} = $header_val;

			if (defined($print_seq_ids)) {
				print(STDOUT "seq id: $seq_id\tname: $base_name\tfile: $header_val\n");
			}
		}

		elsif ($line =~ /^>/) {
			last();
		}
	}

	close(XMFA);

	if (defined($print_seq_ids)) {
		exit(0);
	}

	foreach my $seq_id (keys %seq_base_names) {
		if (@includes && ! exists($includes{$seq_id})) {
			next();
		}

		$seq_names{$seq_id} = $seq_id;

		if ($use_seq_names == 1 && exists($seq_base_names{$seq_id})) {
			$seq_names{$seq_id} = $seq_base_names{$seq_id};
		}

		my $seq_name = $seq_names{$seq_id};

		if (defined($coords_file)) {
			my $seq_id_fasta_file = "$fasta_dir/$seq_name"."$fasta_postfix";

			open($seq_id_fasta_fhs{$seq_id}, '>', $seq_id_fasta_file) or error("can't open fasta file: $!");

			my $fasta_fh = $seq_id_fasta_fhs{$seq_id};

			print($fasta_fh ">$seq_name\n");
		}
	}

	foreach my $seq_id (@sort_order) {
		if (exists($header_seq_ids{$seq_id})) {
			delete($header_seq_ids{$seq_id});
		}

		else {
			error("seq id: $seq_id not found in $xmfa_file header\nrun '$0 -x $xmfa_file -p' to see available seq ids");
		}
	}

	foreach my $seq_id (sort { $a <=> $b } keys %header_seq_ids) {
		push(@sort_order, $seq_id);
	}

	return(0);
}


sub error {
	my $msg = shift();

	if (defined($msg)) {
		print(STDERR "error: $msg\n");
	}

	exit(0);
}


sub arg_error {
	my $msg = shift();

	if (defined($msg)) {
		print(STDERR "error: $msg\n\n");
	}

	print("use option -h or --help to display help menu\n");

	exit(0);
}


sub parse_args {
	if ($#ARGV == -1) {
		pod2usage(-exitval => 0, -verbose => 1);
	}

	GetOptions ('x|xfma=s' => \$xmfa_file,
				'p|print' => \$print_seq_ids,
				's|sort' => \$enable_sort,
				'gapfilter!' => \$enable_invalid_gap_filter,
				'o|order=s{,}' => \@sort_order,
				'seqnames!' => \$use_seq_names,
				'i|include=s{,}' => \@includes,
				'fastadir=s' => \$fasta_dir,
				'fapostfix=s' => \$fasta_postfix,
				'l|linker=s' => \$fasta_linker,
				'c|coords=s' => \$coords_file,
				'xmfaout=s' => \$output_xmfa_file,
				'g|gfa=s' => \$gfa_file,
				'gfapostfix=s' => \$gfa_postfix,
				'v|vg=s' => \$vg_path,
				't|threads=i' => \$threads,
				'n|null=s' => \$null_record,
				'h|help' => \$help) or error('cannot parse arguments');

	if (defined($help)) {
		pod2usage(-exitval => 0, -verbose => 1);
	}

	if (! defined($xmfa_file)) {
		arg_error('xmfa file required');
	}

	if (! defined($print_seq_ids) && ! defined($output_xmfa_file) && ! defined($gfa_file) && ! defined($coords_file)) {
		arg_error('at least one output file must be specified');
	}

	if (defined($output_xmfa_file)) {
		if ($enable_sort == 0 && $enable_invalid_gap_filter == 0 && (! @includes)) {
			arg_error('--xmfaout requires either -s/--sort or -i/--include or gap filtering enabled (do not set --nogapfilter)');
		}
	}

	foreach my $include (@includes) {
		$includes{$include}++;
	}

	if (defined($coords_file)) {
		$fasta_dir =~ s/\/$//;

		if (! -e $fasta_dir) {
			my $cmd = "mkdir -p $fasta_dir";

			system($cmd);
		}
	}

	if (defined($gfa_file)) {
		if (defined($vg_path)) {
			if (! -e $vg_path) {
				error("vg path: $vg_path does not exist");
			}
		}

		else {
			$vg_path = qx(which vg);

			chomp($vg_path);

			if (! defined($vg_path) || $vg_path eq '') {
				error('vg not found in $PATH, specify using -v/--vg option');
			}

			print(STDOUT "using vg found at $vg_path\n");
		}

		if (defined($threads) && $threads < 1) {
			error('number of threads must be a positive integer');
		}
	}
}


__END__

=head1 NAME

xmfa_tools.pl

=head1 SYNOPSIS

xmfa_tools.pl -x xmfa.file [options]

=head1 DESCRIPTION

process XMFA files with a variety of options, generate various output files

=head1 AUTHOR

Brian Abernathy

=head1 OPTIONS

=head2 required

 -x --xmfa     input xmfa file (required)

=head2 processing

 -p --print    print xmfa seq ids, names and files, then exit

 -s --sort     enable block sorting

 -o --order    sort order
                 provide one or more seq ids (from header)
                 default: sort by 1, 2, 3... 
                 example: --order 2 3 1 (sort by 2, then 3, then 1)
                 example: --order 3 (sort by 3, then 1, then 2)

 --nogapfilter disable invalid gap filter
                 default: invalid gap filtering is enabled
                 invalid gap example:
                 ACTAGCTGATG--------CTGACGTAATCGTGATGATCGATGCTGA
                 ACTAGCTGATGCTGACGTA--------ATCGTGATGATCGATGCTGA
                 ACTAGCTGATGCTGACGTA--------ATCGTGATGATCGATGCTGA

 --noseqnames  disable use of seq names in fasta and gfa files
                 By default, seq names (viewed using -p option)
                 are used to name output fasta files and gfa path
                 records. The --noseqnames option will disable
                 the use of seq names and use seq ids instead.

 -i --include  include only specified seq ids in output
                 default: include all
                 example: --include 1 3 7

 -t --threads  number of vg threads to use for gfa processing
                 Current vg versions yield a very modest gain
                 in processing speed with multithreading enabled.
                 default: 1

=head2 output

 --xmfaout     output xmfa file (requires -s/--sort or
                 -i/--include)

 -g --gfa      output gfa file (vg-based, similar to v1 spec)

 --gfapostfix  include gfa seq postfix in gfa path records
                 default: no postfix
                 example: --gfapostfix ".chr01"

 -v --vg       path to vg executable (required for gfa processing)
                 default: autodetect in $PATH (if available)

 -c --coords   output fasta coords file
                 specifying a fasta coords file will generate
                 a gapped fasta file for each (selected) sequence

 -n --null     output fasta coords null record value
                 default: "NA"

 --fastadir    output fasta directory
                 default: current working directory

 --fapostfix   output gapped fasta file postfix
                 default: ".sort.gapped.fa"

 -l --linker   output fasta block sequence linker
                 default: no linker
                 example: -l "NNNNNNNNNN"

=head2 help 

 -h --help     display help menu

=cut
