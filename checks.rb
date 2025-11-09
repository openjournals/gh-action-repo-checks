require "find"
require "open3"
require "rugged"
require "linguist"
require "licensee"
require "json"
require "set"

issue_id = ENV["ISSUE_ID"]
repo_url = ENV["REPO_URL"]
repo_branch = ENV["PAPER_BRANCH"]

# Helper method to detect the first commit date
def detect_first_commit_date(repo)
  walker = Rugged::Walker.new(repo)
  walker.sorting(Rugged::SORT_DATE | Rugged::SORT_REVERSE)
  walker.push(repo.head.target_id)

  first_commit = walker.first
  return nil if first_commit.nil?

  {
    date: first_commit.time.strftime("%B %d, %Y"),
    timestamp: first_commit.time.to_i
  }
end

# Helper method to detect repo dumps (rapid code additions)
def detect_repo_dump(repo)
  walker = Rugged::Walker.new(repo)
  walker.sorting(Rugged::SORT_DATE | Rugged::SORT_REVERSE)
  walker.push(repo.head.target_id)

  commits = walker.to_a
  return nil if commits.length < 2

  # Calculate total insertions (excluding binary files)
  total_insertions = 0
  commits.each do |commit|
    next if commit.parents.empty?
    diff = commit.parents.first.diff(commit)
    diff.each_patch do |patch|
      next if patch.delta.binary?
      total_insertions += patch.stat[0] # stat returns [additions, deletions]
    end
  end

  return nil if total_insertions == 0

  # Analyze 48-hour windows and collect all results
  windows = []

  commits.each_with_index do |commit, idx|
    window_end = commit.time
    window_start = window_end - (48 * 60 * 60) # 48 hours

    window_insertions = 0
    window_commits = []
    commits[0..idx].each do |window_commit|
      next if window_commit.time < window_start
      next if window_commit.parents.empty?

      commit_insertions = 0
      diff = window_commit.parents.first.diff(window_commit)
      diff.each_patch do |patch|
        next if patch.delta.binary?
        commit_insertions += patch.stat[0] # stat returns [additions, deletions]
      end

      if commit_insertions > 0
        window_insertions += commit_insertions
        window_commits << window_commit
      end
    end

    next if window_insertions == 0

    percentage = (window_insertions.to_f / total_insertions * 100).round(1)

    # Get first and last commit SHAs in the window
    first_sha = window_commits.first&.oid&.to_s
    last_sha = window_commits.last&.oid&.to_s

    windows << {
      percentage: percentage,
      window_start: window_start,
      window_end: window_end,
      insertions: window_insertions,
      first_sha: first_sha,
      last_sha: last_sha
    }
  end

  # Sort by percentage descending
  sorted_windows = windows.sort_by { |w| -w[:percentage] }

  # Deduplicate overlapping windows - keep only non-overlapping top windows
  top_windows = []
  sorted_windows.each do |window|
    # Check if this window overlaps significantly with any already selected window
    overlaps = top_windows.any? do |selected|
      # Windows overlap if they share any time period
      !(window[:window_end] < selected[:window_start] || window[:window_start] > selected[:window_end])
    end

    # If it doesn't overlap, or if we have less than 3, add it
    unless overlaps
      top_windows << window
      break if top_windows.length >= 3
    end
  end

  return nil if top_windows.empty?

  # Add signal levels to top windows
  top_windows.each do |window|
    window[:signal] = if window[:percentage] >= 75
      "critical"
    elsif window[:percentage] >= 50
      "strong"
    elsif window[:percentage] >= 25
      "moderate"
    else
      "healthy"
    end
  end

  top_windows
end

# Helper method to parse GitHub repo URL
def parse_github_url(repo_url)
  return nil if repo_url.nil? || repo_url.empty?

  # Match github.com URLs
  match = repo_url.match(/github\.com[\/:]([^\/]+)\/([^\/\.]+)/i)
  return nil unless match

  {
    owner: match[1],
    repo: match[2]
  }
end

# Helper method to get external engagement metrics
def get_external_engagement(repo_url)
  github_info = parse_github_url(repo_url)
  return nil unless github_info

  repo_name = "#{github_info[:owner]}/#{github_info[:repo]}"

  # Get contributors via API
  puts "DEBUG: Fetching contributors for #{repo_name}..."
  contributors_stdout, contributors_stderr, contributors_status = Open3.capture3("gh api repos/#{repo_name}/contributors --paginate --jq 'length'")
  puts "DEBUG: Contributors command exit status: #{contributors_status.exitstatus}"
  puts "DEBUG: Contributors stderr: #{contributors_stderr}" unless contributors_stderr.empty?

  contributor_count = contributors_status.success? ? contributors_stdout.strip.to_i : 0

  # Get releases
  puts "DEBUG: Fetching releases for #{repo_name}..."
  releases_stdout, releases_stderr, releases_status = Open3.capture3("gh release list --repo #{repo_name} --limit 1000 --json tagName")
  puts "DEBUG: Releases command exit status: #{releases_status.exitstatus}"
  puts "DEBUG: Releases stderr: #{releases_stderr}" unless releases_stderr.empty?

  release_count = 0
  if releases_status.success?
    begin
      releases = JSON.parse(releases_stdout)
      release_count = releases.size
    rescue JSON::ParserError
      release_count = 0
    end
  end

  # Get stars and forks via API
  puts "DEBUG: Fetching repo metadata for #{repo_name}..."
  repo_stdout, repo_stderr, repo_status = Open3.capture3("gh api repos/#{repo_name} --jq '{stars: .stargazers_count, forks: .forks_count}'")
  puts "DEBUG: Repo metadata exit status: #{repo_status.exitstatus}"
  puts "DEBUG: Repo metadata stderr: #{repo_stderr}" unless repo_stderr.empty?

  stars = 0
  forks = 0
  if repo_status.success?
    begin
      repo_data = JSON.parse(repo_stdout)
      stars = repo_data["stars"] || 0
      forks = repo_data["forks"] || 0
    rescue JSON::ParserError
      stars = 0
      forks = 0
    end
  end

  # Get issues with comments
  puts "DEBUG: Fetching issues for #{repo_name}..."
  issues_stdout, issues_stderr, issues_status = Open3.capture3("gh issue list --repo #{repo_name} --limit 1000 --state all --json author,comments")
  puts "DEBUG: Issues command exit status: #{issues_status.exitstatus}"
  puts "DEBUG: Issues stdout length: #{issues_stdout.length}"
  puts "DEBUG: Issues stderr: #{issues_stderr}" unless issues_stderr.empty?

  # Get PRs with comments and reviews
  puts "DEBUG: Fetching PRs for #{repo_name}..."
  prs_stdout, prs_stderr, prs_status = Open3.capture3("gh pr list --repo #{repo_name} --limit 1000 --state all --json author,comments,reviews")
  puts "DEBUG: PRs command exit status: #{prs_status.exitstatus}"
  puts "DEBUG: PRs stdout length: #{prs_stdout.length}"
  puts "DEBUG: PRs stderr: #{prs_stderr}" unless prs_stderr.empty?

  return nil unless issues_status.success? && prs_status.success?

  begin
    issues = JSON.parse(issues_stdout)
    prs = JSON.parse(prs_stdout)
    puts "DEBUG: Parsed #{issues.size} issues and #{prs.size} PRs"

    # Collect all unique non-author participants (commenters and reviewers)
    participants = Set.new

    # Process issues - count comment authors
    issues.each do |item|
      author = item["author"]&.fetch("login", nil)
      next unless author

      item["comments"]&.each do |comment|
        login = comment["author"]&.fetch("login", nil)
        participants.add(login) if login && login != author
      end
    end

    # Process PRs - count comment and review authors
    prs.each do |item|
      author = item["author"]&.fetch("login", nil)
      next unless author

      item["comments"]&.each do |comment|
        login = comment["author"]&.fetch("login", nil)
        participants.add(login) if login && login != author
      end

      item["reviews"]&.each do |review|
        login = review["author"]&.fetch("login", nil)
        participants.add(login) if login && login != author
      end
    end

    puts "DEBUG: Found #{participants.size} unique non-author participants"

    {
      unique_participants: participants.size,
      issue_count: issues.size,
      pr_count: prs.size,
      contributor_count: contributor_count,
      release_count: release_count,
      stars: stars,
      forks: forks
    }
  rescue JSON::ParserError, StandardError => e
    puts "DEBUG: Error parsing JSON or processing data: #{e.message}"
    puts "DEBUG: Backtrace: #{e.backtrace.first(3).join("\n")}"
    nil
  end
end

# Helper method to build external engagement section
def build_external_engagement_section(repo_url)
  engagement = get_external_engagement(repo_url)

  # Only show section for GitHub repos
  github_info = parse_github_url(repo_url)
  return nil unless github_info

  section = "\n### GitHub Activity Metrics\n\n"

  if engagement
    section += "| Metric | Count |\n"
    section += "|--------|------:|\n"
    section += "| GitHub stars | #{engagement[:stars]} |\n"
    section += "| Forks | #{engagement[:forks]} |\n"
    section += "| GitHub contributors | #{engagement[:contributor_count]} |\n"
    section += "| Releases | #{engagement[:release_count]} |\n"
    section += "| Total issues | #{engagement[:issue_count]} |\n"
    section += "| Total pull requests | #{engagement[:pr_count]} |\n"
    section += "| Unique commenters/reviewers (excluding authors) | #{engagement[:unique_participants]} |\n"
  else
    section += "Unable to fetch GitHub activity data\n"
  end

  section
end

# Helper method to build repository history section
def build_repository_history_section(repo, repo_url)
  sections = []

  # First commit date
  first_commit_info = detect_first_commit_date(repo)
  if first_commit_info
    sections << "**Repository age:** First commit on #{first_commit_info[:date]}"
  end

  # Repo dump detection - now returns top 3 windows
  top_windows = detect_repo_dump(repo)
  if top_windows && top_windows.any? { |w| w[:percentage] >= 25 }
    # Parse GitHub URL for compare links
    github_info = parse_github_url(repo_url)

    # Build table header
    table = "\n**Code distribution (top 3 48-hour windows):**\n\n"
    table += "| Period | Insertions | % of Total | Signal | View Changes |\n"
    table += "|--------|------------|------------|--------|-------------|\n"

    top_windows.each do |window|
      icon = case window[:signal]
      when "critical" then "🔴"
      when "strong" then "🟠"
      when "moderate" then "🟡"
      else "🟢"
      end

      window_start_date = window[:window_start].strftime("%b %d, %Y")
      window_end_date = window[:window_end].strftime("%b %d, %Y")
      period = "#{window_start_date} - #{window_end_date}"

      signal_text = icon

      # Create compare link if GitHub
      if github_info && window[:first_sha] && window[:last_sha]
        if window[:first_sha] == window[:last_sha]
          # Single commit - link to the commit directly
          commit_url = "https://github.com/#{github_info[:owner]}/#{github_info[:repo]}/commit/#{window[:last_sha]}"
          view_link = "[View commit](#{commit_url})"
        else
          # Multiple commits - show compare view
          # Use first_sha^...last_sha to include the first commit in the range
          compare_url = "https://github.com/#{github_info[:owner]}/#{github_info[:repo]}/compare/#{window[:first_sha]}^...#{window[:last_sha]}"
          view_link = "[View diff](#{compare_url})"
        end
      else
        view_link = "-"
      end

      table += "| #{period} | #{window[:insertions]} | #{window[:percentage]}% | #{signal_text} | #{view_link} |\n"
    end

    sections << table
  end

  return nil if sections.empty?

  "\n### Repository History\n\n" + sections.join("\n\n")
end

paper_path = nil

# Build consolidated repository analysis report
repo = Rugged::Repository.new(".")

# Get CLOC results
cloc_output = Open3.capture3("cloc --quiet .")[0].strip

# Get git authors
git_authors = Open3.capture3("git shortlog -sn --no-merges --branches .")[0].strip

# Build repository history section
repo_history = build_repository_history_section(repo, repo_url)

# Build external engagement section
external_engagement = build_external_engagement_section(repo_url)

# Consolidate into single report
repo_analysis_report = <<~REPOANALYSIS
  ## Repository Analysis Report

  ### Software Summary

  ```
  #{cloc_output}
  ```

  ### Commit Count by Author

  ```
  #{git_authors}
  ```
  #{repo_history}
  #{external_engagement}
REPOANALYSIS

File.open("repo-analysis.txt", "w") do |f|
  f.write repo_analysis_report
end
system("gh issue comment #{issue_id} --body-file repo-analysis.txt")

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
  word_count_icon = word_count > 1999 ? "🚨" : (word_count > 1200 ? "⚠️" : "📄")
  word_count_msg = "#{word_count_icon} Wordcount for `#{File.basename(paper_path)}` is **#{word_count}**"

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
project = Linguist::Repository.new(repo, repo.head.target_id)
ordered_languages = project.languages.sort_by { |_, size| size }.reverse
top_3 = ordered_languages.first(3).map {|l,s| l}

system("gh issue edit #{issue_id} --add-label #{top_3*','}") unless top_3.empty?

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
      license_info_msg = "✅ License found: `#{license.name}` (Valid open source [OSI approved](https://opensource.org/licenses) license)"
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
