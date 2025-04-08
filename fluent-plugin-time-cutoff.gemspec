# frozen_string_literal: true

lib = File.expand_path('../lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name    = 'fluent-plugin-time-cutoff'
  spec.version = '0.1.1'
  spec.authors = ['Qrator Labs', 'Serge Tkatchouk']
  spec.email   = ['devops@qrator.net', 'st@qrator.net']

  spec.summary       = 'Fluentd time-based filter plugin.'
  spec.description   = 'A plugin that lets Fluentd to prune/rewrite messages '\
                       'that have a timestamp that is too old or too new.'
  spec.homepage      = 'https://github.com/QratorLabs/fluent-plugin-time-cutoff'
  spec.license       = 'MIT'

  spec.files         = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[test/ testbed/ spec/ features/ .git .circleci appveyor Gemfile])
    end
  end

  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.platform = Gem::Platform::RUBY
  spec.required_ruby_version = Gem::Requirement.new('>= 2.3')

  spec.add_runtime_dependency 'fluentd', ['>= 0.14.10', '< 2']

  spec.add_development_dependency 'bundler', '~> 2.6.3'
  spec.add_development_dependency 'rake', '~> 13.1.0'
  spec.add_development_dependency 'test-unit', '~> 3.6.1'
end
