# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = "kanjian.la"
  spec.version       = "0.1.0"
  spec.authors       = ["seven-steven"]
  spec.email         = ["seven@diqigan.cn"]

  spec.summary       = "A navigation theme for jekyll"
  spec.homepage      = "https://kanjian.la"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0").select { |f| f.match(%r!^(assets|_layouts|_includes|_sass|LICENSE|README|_config\.yml)!i) }

  spec.add_runtime_dependency "jekyll", "3.9.1"
end
