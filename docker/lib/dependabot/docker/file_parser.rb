# typed: strong
# frozen_string_literal: true

require "dependabot/shared/shared_file_parser"
require "dependabot/docker/package_manager"

module Dependabot
  module Docker
    class FileParser < Dependabot::Shared::SharedFileParser
      extend T::Sig

      YAML_REGEXP = /^[^\.].*\.ya?ml$/i
      QUADLET_REGEXP = /\.(?:container|image|volume|artifact)$/
      # Quadlet keys are case-sensitive; whitespace around "=" is ignored by the unit file parser.
      QUADLET_IMAGE_LINE = /^\s*(?:Image|Artifact)\s*=\s*(?<reference>\S+)/
      FROM = /FROM/i
      PLATFORM = /--platform\=(?<platform>\S+)/
      TAG_NO_PREFIX = /(?<tag>[\w][\w.-]{0,127})/
      TAG = /:#{TAG_NO_PREFIX}/
      DIGEST = /(?<digest>[0-9a-f]{64})/

      FROM_LINE =
        %r{^#{FROM}\s+(#{PLATFORM}\s+)?(#{REGISTRY}/)?
          #{IMAGE}#{TAG}?(?:@sha256:#{DIGEST})?#{NAME}?}x

      IMAGE_SPEC = %r{^(#{REGISTRY}/)?#{IMAGE}#{TAG}?(?:@sha256:#{DIGEST})?#{NAME}?}x
      TAG_WITH_DIGEST = /^#{TAG_NO_PREFIX}(?:@sha256:#{DIGEST})?/x

      sig { returns(Ecosystem) }
      def ecosystem
        @ecosystem ||= T.let(
          Ecosystem.new(
            name: ECOSYSTEM,
            package_manager: DockerPackageManager.new
          ),
          T.nilable(Ecosystem)
        )
      end

      sig { override.returns(T::Array[Dependabot::Dependency]) }
      def parse
        dependency_set = DependencySet.new

        dockerfiles.each do |dockerfile|
          T.must(dockerfile.content).each_line do |line|
            next unless FROM_LINE.match?(line)

            parsed_from_line = T.must(FROM_LINE.match(line)).named_captures
            parsed_from_line["registry"] = nil if parsed_from_line["registry"] == "docker.io"

            version = version_from(parsed_from_line)
            next unless version

            dependency_set << build_dependency(dockerfile, parsed_from_line, version)
          end
        end

        quadlet_files.each do |file|
          dependency_set += quadlet_file_dependencies(file)
        end

        manifest_files.each do |file|
          dependency_set += workfile_file_dependencies(file)
        rescue Dependabot::DependencyFileNotParseable => e
          Dependabot.logger.warn("Failed to parse YAML file #{file.path}: #{e.message}")
        end

        dependency_set.dependencies
      end

      private

      sig { override.returns(String) }
      def package_manager
        "docker"
      end

      sig { override.returns(String) }
      def file_type
        "Dockerfile"
      end

      sig { returns(T::Array[Dependabot::DependencyFile]) }
      def dockerfiles
        # The Docker file fetcher fetches Dockerfiles, Quadlet units and yaml files. Reject the latter two.
        dependency_files.reject do |f|
          f.type == "file" && (f.name.match?(YAML_REGEXP) || f.name.match?(QUADLET_REGEXP))
        end
      end

      sig { returns(T::Array[Dependabot::DependencyFile]) }
      def quadlet_files
        dependency_files.select { |f| f.type == "file" && f.name.match?(QUADLET_REGEXP) }
      end

      sig { returns(T::Array[Dependabot::DependencyFile]) }
      def manifest_files
        dependency_files.select { |f| f.type == "file" && f.name.match?(YAML_REGEXP) }
      end

      sig { params(file: Dependabot::DependencyFile).returns(DependencySet) }
      def quadlet_file_dependencies(file)
        dependency_set = DependencySet.new

        T.must(file.content).each_line do |line|
          reference = QUADLET_IMAGE_LINE.match(line)&.[](:reference)
          next unless reference

          dependency = dependency_from_reference(file, reference)
          dependency_set << dependency if dependency
        end

        dependency_set
      end

      sig { params(file: Dependabot::DependencyFile).returns(DependencySet) }
      def workfile_file_dependencies(file)
        dependency_set = DependencySet.new

        resources = T.must(file.content).split(/^---$/).map(&:strip).reject(&:empty?)
        resources.flat_map do |resource|
          json = YAML.safe_load(resource, aliases: true)
          images = deep_fetch_images(json).uniq

          images.each do |string|
            dependency = dependency_from_reference(file, string)
            dependency_set << dependency if dependency
          end
        end

        dependency_set
      rescue Psych::SyntaxError, Psych::DisallowedClass, Psych::BadAlias => e
        raise Dependabot::DependencyFileNotParseable.new(file.path, e.message)
      end

      sig do
        params(file: Dependabot::DependencyFile, reference: String).returns(T.nilable(Dependabot::Dependency))
      end
      def dependency_from_reference(file, reference)
        # TODO: Support Docker references and path references
        details = reference.match(IMAGE_SPEC)&.named_captures
        return if details.nil?

        details["registry"] = nil if details["registry"] == "docker.io"

        version = version_from(details)
        return unless version

        build_dependency(file, details, version)
      end

      sig { params(json_obj: T.anything).returns(T::Array[String]) }
      def deep_fetch_images(json_obj)
        case json_obj
        when Hash then deep_fetch_images_from_hash(json_obj)
        when Array then json_obj.flat_map { |o| deep_fetch_images(o) }
        else []
        end
      end

      sig { params(json_object: T::Hash[Object, Object]).returns(T::Array[String]) }
      def deep_fetch_images_from_hash(json_object)
        img = json_object.fetch("image", nil)

        images =
          if !img.nil? && img.is_a?(String) && !img.empty?
            [img]
          elsif !img.nil? && img.is_a?(Hash) && !img.empty?
            parse_helm(img)
          else
            []
          end

        images + json_object.values.flat_map { |obj| deep_fetch_images(obj) }
      end

      sig { params(img_hash: T::Hash[Object, Object]).returns(T::Array[String]) }
      def parse_helm(img_hash)
        tag_value = img_hash.key?("tag") ? img_hash.fetch("tag", nil) : img_hash.fetch("version", nil)
        return [] unless tag_value

        repo = img_hash.fetch("repository", nil)
        return [] unless repo.is_a?(String)

        tag = tag_value.to_s
        # Helm template expressions cannot be resolved without rendering the chart.
        return [] if tag.include?("{{")

        match = tag.match(TAG_WITH_DIGEST)
        return [] unless match

        tag_details = match.named_captures
        tag = tag_details["tag"]
        return [repo] unless tag

        registry = img_hash.fetch("registry", nil)
        digest = tag_details["digest"]

        image = "#{repo}:#{tag}"
        image.prepend("#{registry}/") if registry
        image << "@sha256:#{digest}/" if digest
        [image]
      end

      sig { override.void }
      def check_required_files
        return if dependency_files.any?

        raise "No #{file_type}!"
      end
    end
  end
end

Dependabot::FileParsers.register("docker", Dependabot::Docker::FileParser)
