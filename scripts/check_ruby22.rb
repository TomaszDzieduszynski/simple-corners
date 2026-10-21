# Checks that the plugin sources parse as Ruby 2.2 (SketchUp 2017) and do
# not use methods added in later Ruby versions.
# Usage: gem install parser && ruby scripts/check_ruby22.rb
require 'parser/ruby22'

NEWER = {
  'sum' => '2.4', 'clamp' => '2.4', 'match?' => '2.4', 'transform_values' => '2.4',
  'transform_keys' => '2.5', 'filter_map' => '2.7', 'then' => '2.6', 'yield_self' => '2.5',
  'dig' => '2.3', 'filter' => '2.6',
  'delete_prefix' => '2.5', 'delete_suffix' => '2.5', 'tally' => '2.7', 'intersect?' => '3.1'
}.freeze

def walk(node, file, issues)
  return unless node.is_a?(Parser::AST::Node)
  if %i[send csend].include?(node.type)
    issues << "#{file}:#{node.loc.line}: safe navigation (&.) needs Ruby 2.3" if node.type == :csend
    m = node.children[1].to_s
    issues << "#{file}:#{node.loc.line}: ##{m} needs Ruby #{NEWER[m]}" if NEWER.key?(m)
  end
  node.children.each { |c| walk(c, file, issues) }
end

files = Dir[File.join(__dir__, '..', 'src', '**', '*.rb')].sort
issues = []
files.each do |f|
  src = File.read(f, :encoding => 'UTF-8')
  issues << "#{f}: squiggly heredoc (<<~) needs Ruby 2.3" if src =~ /<<~/
  buffer = Parser::Source::Buffer.new(f, source: src)
  parser = Parser::Ruby22.new
  parser.diagnostics.all_errors_are_fatal = true
  parser.diagnostics.consumer = lambda { |d| issues << d.render.join("\n") }
  begin
    walk(parser.parse(buffer), File.basename(f), issues)
  rescue Parser::SyntaxError
    issues << "#{f}: syntax error for Ruby 2.2"
  end
end
if issues.empty?
  puts "OK: #{files.size} files are Ruby 2.2 compatible"
else
  puts issues
  exit 1
end
