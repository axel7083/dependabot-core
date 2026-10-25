# typed: strong
# frozen_string_literal: true

require "sorbet-runtime"
require "dependabot/file_fetchers"
require "dependabot/file_fetchers/base"
require "dependabot/shared/shared_file_updater"

module Dependabot
  module Docker
    class FileUpdater < Dependabot::Shared::SharedFileUpdater
      extend T::Sig

      YAML_REGEXP = /^[^\.].*\.ya?ml$/i
      FROM_REGEX = /FROM(\s+--platform\=\S+)?/i
      # Quadlet keys are case-sensitive; whitespace around "=" is ignored by the unit file parser.
      QUADLET_IMAGE_KEY = /(?:Image|Artifact)\s*=/

      sig { override.returns(String) }
      def file_type
        "Dockerfile or Containerfile"
      end

      sig { override.returns(Regexp) }
      def yaml_file_pattern
        YAML_REGEXP
      end

      sig { override.returns(Regexp) }
      def container_image_regex
        %r{^#{FROM_REGEX}\s+(docker\.io/)?}o
      end

      sig { override.params(escaped_declaration: String).returns(Regexp) }
      def build_old_declaration_regex(escaped_declaration)
        %r{^(?:#{FROM_REGEX}\s+|\s*#{QUADLET_IMAGE_KEY}\s*)(docker\.io/)?#{escaped_declaration}(?=\s|$)}
      end
    end
  end
end

Dependabot::FileUpdaters.register("docker", Dependabot::Docker::FileUpdater)
