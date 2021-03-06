# Shared config mixin used by all Thor namespaced tasks.
#
module Mofa
  module Config
    @@config = {}

    def self.config
      @@config
    end

    def self.load
      unless Dir.exist?("#{ENV['HOME']}/.mofa")
        #warn "Mofa config folder not present! You may use 'mofa setup' to get rid of this message."
        warn "Mofa config folder not present! Please create a folder .mofa in your HOME directory: mkdir ~/.mofa"
      end
      unless File.exist?("#{ENV['HOME']}/.mofa/config.yml")
        #warn "Mofa config file not present at #{ENV['HOME']}/.mofa/config.yml! You may use 'mofa setup' to get rid of this message."
        warn "Mofa config file not present at #{ENV['HOME']}/.mofa/config.yml! Please create a config file first! (see README.md)"
      end
      if File.exist?("#{ENV['HOME']}/.mofa/config.yml")
        @@config = YAML.load(File.open("#{ENV['HOME']}/.mofa/config.yml"))
      end
    end

  end
end
