#
# This script generates a YAML file located at tmp/filename_to_digest_map.yml that contains information about the unresolved references in the cache files
# generated by packwerk and packs
#
# The script will exit early if there is any diff, as it's purpose is similar to `rspec --next-failure` –
# to provide feedback about a failing test to write and fix.
#
# Example usage:
# Use from within a modulith that uses packwerk
#
#   $ ruby path/to/scripts/packwerk_parity_checker.rb
# or
#   $ PACKS_DIR=packs-rs time ruby ../packs-rs/scripts/packwerk_parity_checker.rb 
# also..
# add FAIL_FAST=1 to fail on the first failing file
require 'json'
require 'hashdiff'
require 'pathname'
require 'pry'
require 'yaml'
require 'digest'
require 'ruby-progressbar'
require 'parallel'
require 'sorbet-runtime'

packs_dir = ENV.fetch('PACKS_DIR', 'packs') # could be packs-rs
Dir.chdir("../#{packs_dir}") do
  puts "Running cargo build --release in ../#{packs_dir}"
  system('cargo build --release')
end

command = "CACHE_VERIFICATION=1 time ../#{packs_dir}/target/release/packs generate_cache"
puts "Running: #{command}"
system(command)

class Cache < T::Struct
  const :file, Pathname
  const :unresolved_references, T.untyped

  def self.from(file)
    unresolved_references = sorted_unresolved_references_for(file)
    Cache.new(file:, unresolved_references:)
  end

  def self.sorted_unresolved_references_for(cache_path)
    if cache_path.exist?
      # Sort by constant name and then location (in case there are multiple references)
      JSON.parse(cache_path.read)['unresolved_references'].sort_by{|h| [h['constant_name'], h['source_location']['line'], h['source_location']['column']]}
    else
      []
    end
  end

end

class Result < T::Struct
  const :file, String
  const :original, Cache
  const :experimental, Cache
  const :diff, T.untyped

  def self.from_file(f)
    cache_basename = Digest::MD5.hexdigest(f)
    experimental_cache_basename = "#{cache_basename}-experimental"
    from_filename_digest(cache_basename)
  end

  def self.from_filename_digest(cache_basename)
    cache_dir = Pathname.new('tmp/cache/packwerk')
    experimental_cache_basename = "#{cache_basename}-experimental"
    original = Cache.from(cache_dir.join(cache_basename))
    experimental = Cache.from(cache_dir.join(experimental_cache_basename))
    diff = Hashdiff.diff(original.unresolved_references, experimental.unresolved_references)
    Result.new(original:, experimental:, diff:, file: cache_basename)
  end

  def pretty_print
    lines = []
    lines << "No original cache" if original.nil?
    lines << "No experimental cache" if experimental.nil?

    if success?
      lines << "No difference"
    else

      lines << "===================================="
      lines << "Results for file: #{file}"
      lines << "original cache at #{original.file} has #{original.unresolved_references.count} unresolved references"
      lines << "experimental cache at #{experimental.file} has #{experimental.unresolved_references.count} unresolved references"
      lines << "diff count is #{diff.count}"
      lines << "original cache content: #{get_pretty_printed_string(original.unresolved_references)}"
      lines << "experimental cache content: #{get_pretty_printed_string(experimental.unresolved_references)}"
      lines << "diff is #{get_pretty_printed_string(diff)}"
    end

    "- #{lines.join("\n- ")}"
  end

  def success?
    diff.count == 0
  end

  def get_pretty_printed_string(object)
    output = StringIO.new
    PP.pp(object, output)
    $stdout = STDOUT
    "\n#{output.string}"
  end
end

all_files = Dir.glob("app/**/*.{rb,rake,erb}")
all_experimental_cache_files = Dir['tmp/cache/packwerk/*-experimental']

all_cache_files = Dir['tmp/cache/packwerk/*'] - all_experimental_cache_files
puts "There are #{all_cache_files.count} files in tmp/cache/packwerk"
puts "There are #{all_experimental_cache_files.count} experimental files in tmp/cache/packwerk"

# Shuffle can be used to find a simpler error to fix
all_files.shuffle! if ENV['SHUFFLE']

bar = ProgressBar.create(total: all_files.count, throttle_rate: 1, format: '%a %t [%c/%C files]: %B %j%%, %E')
found_failure = false
success_count = 0
all_count = 0
all_results = Parallel.map(all_files, in_threads: 8) do |f|
  bar.increment
  all_count += 1
  next if found_failure && ENV['FAIL_FAST']
  result = Result.from_file(f)
  if result.success?
    success_count += 1
    bar.log "Success! Success ratio is now: #{(success_count/all_count.to_f*100).round(2)} (#{f} was successful)!"
  else
    bar.log "Failure! Success ratio is now: #{(success_count/all_count.to_f*100).round(2)} (#{f} failed)!"
    found_failure = true
  end
  result
end

all_results.compact.group_by(&:success?).each do |success, results|
  if success
    puts "There are #{results.count} successes out of #{all_results.count} total"
    puts "That's #{(results.count/all_results.count.to_f * 100).round(2)}% of files with a cache generated by packs!"
  else
    puts results.first.pretty_print
  end
end
