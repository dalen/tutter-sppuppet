require 'fileutils'
require 'json'

class Sppuppet
  # Match regexps
  MERGE_COMMENT = /(:shipit:|:ship:|!merge)/
  PLUS_VOTE = /(:+1:|^\+1|^LGTM)/
  MINUS_VOTE = /(:-1:|^-1)/
  BLOCK_VOTE = /^(:poop:|:hankey:|-2)/ # Blocks merge
  INCIDENT = /jira.*INCIDENT/

  def initialize(settings, client, project, data, event)
    @settings = settings
    @settings['plus_ones_required'] ||= 1
    @client = client
    @project = project
    @data = data
    @event = event
  end

  def run
    case @event
    when 'issue_comment'
      if @data['action'] != 'created'
        # Not a new comment, ignore
        return 200, 'not a new comment, skipping'
      end

      if @data['sender']['login'] == @client.user.login
        return 200, 'Skipping own comment'
      end

      pull_request_id = @data['issue']['number']
      merge_command = MERGE_COMMENT.match(@data['comment']['body'])

      return 200, 'Not a merge comment' unless merge_command

      return maybe_merge(pull_request_id, true, @data['sender']['login'])

    when 'status'
      return 200, 'Merge state not clean' unless @data['state'] == 'success'
      commit_sha = @data['commit']['sha']
      @client.pull_requests(@project).each do |pr|
        return maybe_merge(pr.number, false) if pr.head.sha == commit_sha
      end
      return 200, "Found no pull requests matching #{commit_sha}"

    when 'pull_request'
      # If a new pull request is opened, comment with instructions
      if @data['action'] == 'opened' && @settings['post_instructions']
        issue = @data['number']
        comment = @settings['instructions'] || "To merge at least #{@settings['plus_ones_required']} person other than the submitter needs to write a comment containing only _+1_ or :+1:. Then write _!merge_ or :shipit: to trigger merging."
        return post_comment(issue, comment)
      else
        return 200, 'Not posting instructions'
      end
    else
      return 200, "Unhandled event type #{@event}"
    end
  end

  def maybe_merge(pull_request_id, merge_command, merger = nil)
    votes = {}
    incident_merge_override = false
    pr = @client.pull_request @project, pull_request_id

    # We fetch the latest commit and it's date.
    last_commit = @client.pull_request_commits(@project, pull_request_id).last
    last_commit_date = last_commit.commit.committer.date

    comments = @client.issue_comments(@project, pull_request_id)

    # Check each comment for +1 and merge comments
    comments.each do |i|
      # Comment is older than last commit.
      # We only want to check newer comments
      next if last_commit_date > i.created_at

      # Skip comments from tutter itself
      next if i.attrs[:user].attrs[:login] == @client.user.login

      if MERGE_COMMENT.match(i.body)
        merger ||= i.attrs[:user].attrs[:login]
        # Count as a +1 if it is not the author
        unless pr.user.login == i.attrs[:user].attrs[:login]
          votes[i.attrs[:user].attrs[:login]] = 1
        end
      end

      if PLUS_VOTE.match(i.body) && pr.user.login != i.attrs[:user].attrs[:login]
        votes[i.attrs[:user].attrs[:login]] = 1
      end

      if MINUS_VOTE.match(i.body) && pr.user.login != i.attrs[:user].attrs[:login]
        votes[i.attrs[:user].attrs[:login]] = -1
      end

      if BLOCK_VOTE.match(i.body)
        msg = 'Commit cannot be merged so long as a -2 comment appears in the PR.'
        return post_comment(pull_request_id, msg)
      end

      if INCIDENT.match(i.body)
        incident_merge_override = true
      end
    end

    if pr.mergeable_state != 'clean' && !incident_merge_override
      msg = "Merge state for is not clean. Current state: #{pr.mergeable_state}\n"
      reassure = "I will try to merge this for you when the builds turn green\n" +
        "If your build fails or becomes stuck for some reason, just say 'rebuild'\n" +
        'If you have an incident and want to skip the tests or the peer review, please post the link to the jira ticket.'
      if merge_command
        return post_comment(pull_request_id, msg + reassure)
      else
        return 200, msg
      end
    end

    return 200, 'No merge comment found' unless merger

    num_votes = votes.values.reduce(0) { |a, e| a + e }
    if num_votes < @settings['plus_ones_required'] && !incident_merge_override
      msg = "Not enough plus ones. #{@settings['plus_ones_required']} required, and only have #{num_votes}"
      return post_comment(pull_request_id, msg)
    end

    # TODO: Word wrap description
    merge_msg = <<MERGE_MSG
Title: #{pr.title}
Opened by: #{pr.user.login}
Reviewers: #{votes.keys.join ', '}
Deployer: #{merger}
URL: #{pr.url}
Tests: #{@client.combined_status(@project, pr.head.sha).statuses.map { |s| [s.state, s.description, s.target_url].join(", ") }.join("\n ")}

#{pr.body}
MERGE_MSG
    if incident_merge_override
      @client.add_labels_to_an_issue @project, pull_request_id, ['incident']
    end
    begin
      merge_commit = @client.merge_pull_request(@project, pull_request_id, merge_msg)
    rescue Octokit::MethodNotAllowed => e
      return post_comment(pull_request_id, "Pull request not mergeable: #{e.message}")
    end
    return 200, "merging #{pull_request_id} #{@project}"
  end

  def post_comment(issue, comment)
    begin
      @client.add_comment(@project, issue, comment)
      return 200, "Commented:\n" + comment
    rescue Octokit::NotFound
      return 404, 'Octokit returned 404, this could be an issue with your access token'
    rescue Octokit::Unauthorized
      return 401, "Authorization to #{@project} failed, please verify your access token"
    rescue Octokit::TooManyLoginAttempts
      return 429, "Account for #{@project} has been temporary locked down due to to many failed login attempts"
    end
  end

end
