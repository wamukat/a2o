Gem::Specification.new do |spec|
  spec.name = "a3"
  spec.version = "0.5.0"
  spec.summary = "A3 next-generation orchestration runtime"
  spec.authors = ["Takuma Watanabe"]
  spec.files = Dir[
    "bin/*",
    "lib/**/*.rb"
  ]
  spec.bindir = "bin"
  spec.executables = ["a3"]
  spec.require_paths = ["lib"]
end
