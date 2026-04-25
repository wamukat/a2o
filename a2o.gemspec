Gem::Specification.new do |spec|
  spec.name = "a2o"
  spec.version = "0.5.32"
  spec.summary = "A2O orchestration runtime"
  spec.authors = ["wamukat"]
  spec.files = Dir[
    "bin/*",
    "lib/**/*.rb"
  ]
  spec.bindir = "bin"
  spec.executables = ["a3"]
  spec.require_paths = ["lib"]
end
