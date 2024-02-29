require "find"
require "open3"
require "rugged"
require "linguist"
require "licensee"

issue_id = ENV["ISSUE_ID"]
repo_url = ENV["REPO_URL"]
repo_branch = ENV["PAPER_BRANCH"]

paper_path = nil

Find.find(".").each do |path|
  if path =~ /\/paper\.tex$|\/paper\.md$/
    paper_path = path
    break
  end
end

if paper_path.nil?
  error_msg = "**Paper file info**:\n\n⚠️ Failed to find a paper file in #{repo_url}"
  error_msg += " (branch: #{repo_branch})" unless (repo_branch == "" || repo_branch.nil?)

  File.open("paper-analysis.txt", "w") do |f|
    f.write error_msg
  end
else

  # Count paper file length
  word_count = Open3.capture3("cat #{paper_path} | wc -w")[0].to_i
  word_count_msg = "📄 Wordcount for `#{File.basename(paper_path)}` is **#{word_count}**"

  # Detect a "Statement of need" section
  paper_file_text = File.open(paper_path).read
  if paper_file_text =~ /# Statement of Need/i
    statemend_of_need_msg = "✅ The paper includes a `Statement of need` section"
  else
    statemend_of_need_msg = "🔴 Failed to discover a `Statement of need` section in paper"
  end

  # Build message results
  paper_info = <<~PAPERFILEINFO
    **Paper file info**:

    #{word_count_msg}

    #{statemend_of_need_msg}

  PAPERFILEINFO

  File.open("paper-analysis.txt", "w") do |f|
    f.write paper_info
  end

end

# Post paper info
system("gh issue comment #{issue_id} --body-file paper-analysis.txt")

# Label issue with the top 3 detected languages
repo = Rugged::Repository.new(".")
project = Linguist::Repository.new(repo, repo.head.target_id)
ordered_languages = project.languages.sort_by { |_, size| size }.reverse
top_3 = ordered_languages.first(3).map {|l,s| l}

system("gh issue edit #{issue_id} --add-label #{top_3}") unless top_3.empty?

# Detect license
license = Licensee.project(".").license

if license.nil?
  license_info_msg = "🔴 Failed to discover a valid open source license"
else
  license_info_msg = "🟡 License found: `#{license.name}` ([Check here](https://opensource.org/licenses) for OSI approval)"
  license_xml_path = File.expand_path "#{license.spdx_id}.xml", Licensee::License.spdx_dir
  if File.exist? license_xml_path
    raw_xml = File.read(license_xml_path, encoding: "utf-8")
    if raw_xml.match?(/<license isOsiApproved="true" /)
      license_info_msg = "✅ License found: `#{license.name}`(Valid open source [OSI approved](https://opensource.org/licenses) license)"
    elsif raw_xml.match?(/<license isOsiApproved="false" /)
      license_info_msg = "🔴 License found: `#{license.name}` (Not [OSI approved](https://opensource.org/licenses))"
    end
  end
end

license_info = <<~LICENSEFILEINFO
  **License info**:

  #{license_info_msg}

LICENSEFILEINFO

File.open("license-information.txt", "w") do |f|
  f.write license_info
end
system("gh issue comment #{issue_id} --body-file license-information.txt")
