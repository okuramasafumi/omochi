# frozen_string_literal: true

require 'omochi'
require 'thor'
require 'omochi/util'
require 'yaml'
require 'aws-sdk-bedrockruntime'
require 'dotenv/load'
require 'unparser'

module Omochi
  class CLI < Thor
    class << self
      def exit_on_failure?
        true
      end
    end

    desc 'verify local_path', 'verify spec created for all of new methods and functions'
    method_option :github, aliases: '-h', desc: 'Running on GitHub Action'
    method_option :create, aliases: '-c', desc: 'Create Spec for Untested Method'
    def verify
      is_gh_action = options[:github] == 'github'
      is_gl_ci_runner = false
      create_spec = options[:create] == 'create'

      perfect = true
      spec_def_name_arr = []

      case [is_gh_action, is_gl_ci_runner]
      when [true, false]
        diff_paths = github_diff_path
      when [false, true]
        diff_paths = remote_diff_path
      when [false, false]
        diff_paths = local_diff_path
      end

      # Ruby 以外のファイル(yamlやmdなど)を除外 specファイルも除外(テストにはテストない)
      diff_paths = diff_paths.reject { |s| !s.end_with?('.rb') || s.end_with?('_spec.rb') }
      p "Verify File List: #{diff_paths}"

      # diff_paths 例: ["lib/omochi/cli.rb", "lib/omochi/util.rb"]
      diff_paths.each do |diff_path|
        result = {}
        spec_file_path = find_spec_file(diff_path)
        ignored_def_names = get_ignore_methods(diff_path)

        if !spec_file_path.nil?
          p 'specファイルあり'
          # ここから対応するSpecファイルが存在した場合のロジック
          # スペックファイルがあれば、specfileの中身を確認していく。
          # defメソッド名だけ切り出す {:call => {code}, :verify => {code}, ....}
          exprs = get_ast(diff_path)

          # ASTを再帰的に探索し、メソッド名とコードを取得
          exprs.each do |expr|
            dfs(expr[:ast], expr[:filename], result)
          end
          result = result.transform_keys(&:to_s)
          # describeメソッド [call]
          exprs = get_ast(spec_file_path) # []の中にastが入る
          exprs.each do |expr|
            spec_def_name_arr = dfs_describe(expr[:ast], expr[:filename], spec_def_name_arr)
          end
          # resultのHashでSpecが存在するものをTrueに更新
          spec_def_name_arr.each do |spec_def_name|
            next unless result.key?(spec_def_name)

            result[spec_def_name] = true

            next unless create_spec

            result.each do |method_code|
              next if method_code[1] == true

              code = method_code[1]
              puts '==================================================================='
              puts "#{spec_def_name} のテストを以下に表示します。"
              create_spec_by_bedrock(method_code)
            end
          end

          ignored_def_names.each do |def_name|
            result[def_name] = true if result.key?(def_name)
          end
          perfect = false if print_result(diff_path, result).size > 0
        else
          # ここから対応するSpecファイルが存在しない場合のロジック
          p 'specファイルなし'
          exprs = get_ast(diff_path)

          exprs.each do |expr|
            dfs(expr[:ast], expr[:filename], result)
          end
          result = result.transform_keys(&:to_s)
          ignored_def_names.each do |def_name|
            result[def_name] = true if result.key?(def_name)
          end

          perfect = false if print_result(diff_path, result).size > 0

          if create_spec
            # exprs[0] の AST からメソッド内のコードを生成
            ast_code = exprs[0][:ast]
            method_code = Unparser.unparse(ast_code)

            puts '==================================================================='
            puts "#{diff_path} のテストを以下に表示します。"
            create_spec_by_bedrock(method_code)
          end
        end
      end
      # perfect じゃない場合は、異常終了する
      exit(perfect ? 0 : 1)
    end
  end
end
