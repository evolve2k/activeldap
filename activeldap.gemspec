# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)

Gem::Specification.new do |s|
  s.name        = "activeldap"
  s.version     = "1.0.9"
  s.authors     = ["Some amazing people"]
  s.email       = ["evolve2k@gmail.com"]
  s.homepage    = ""
  s.summary     = "It does what it says on the packet"
  s.description = "ActiveLDAP what more to say"

  s.rubyforge_project = "activeldap"

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]

  # specify any dependencies here; for example:
  # s.add_development_dependency "rspec"
  # s.add_runtime_dependency "rest-client"
end
