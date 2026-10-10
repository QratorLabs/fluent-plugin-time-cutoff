# frozen_string_literal: true

lib = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name    = 'fluent-plugin-time-cutoff'
  spec.version = '0.3.0'
  spec.authors = ['Qrator Labs', 'Serge Tkatchouk']
  spec.email   = ['devops@qrator.net', 'st@qrator.net']

  spec.summary       = 'Fluentd time-based filter plugin.'
  spec.description   = 'A plugin that lets Fluentd to prune/rewrite messages '\
                       'that have a timestamp that is too old or too new.'
  spec.homepage      = 'https://github.com/QratorLabs/fluent-plugin-time-cutoff'
  spec.license       = 'MIT'

  spec.files         = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == File.basename(__FILE__)) ||
        f.start_with?(*%w[test/ testbed/ spec/ features/ .git .circleci appveyor Gemfile Rakefile .rubocop.yml])
    end
  end

  spec.require_paths = ['lib']

  spec.platform = Gem::Platform::RUBY
  spec.required_ruby_version = Gem::Requirement.new('>= 2.7')

  spec.add_runtime_dependency 'fluentd', ['>= 0.14.10', '< 2']

  spec.add_development_dependency 'rake', '~> 13.2.0'
  spec.add_development_dependency 'test-unit', '~> 3.6.1'
end
