require 'csv'
require 'pry'

def analysis(fin, fout, fhint, furls, fdefmaps, fskip, franges)
  sort_col = 'authors'

  # Repos, Orgs and Projects to skip
  skip_repos = {}
  skip_orgs = {}
  skip_projs = {}
  CSV.foreach(fskip, headers: true) do |row|
    h = row.to_h
    org = (h['org'] || '').strip
    repo = (h['repo'] || '').strip
    proj = (h['project'] || '').strip
    if org.length > 0
      orgs = org.split(',')
      orgs.each do |o|
        if skip_orgs.key?(o)
          puts "Duplicate skip org entry: #{o}"
          return
        end
        skip_orgs[o] = true
      end
    end
    if repo.length > 0
      reps = repo.split(',')
      reps.each do |r|
        if skip_repos.key?(r)
          puts "Duplicate skip repo entry: #{r}"
          return
        end
        skip_repos[r] = true
      end
    end
    if proj.length > 0
      projs = proj.split(',')
      projs.each do |p|
        if skip_projs.key?(p)
          puts "Duplicate skip project entry: #{p}"
          return
        end
        skip_projs[p] = true
      end
    end
  end

  # Min/Max ranges for integer columns (with exceptions)
  ranges = {}
  CSV.foreach(franges, headers: true) do |row|
    h = row.to_h
    key = h['key'].strip
    min = h['min'].strip
    max = h['max'].strip
    exc = (h['exceptions'] || '').strip
    rps = {}
    ors = {}
    excs = exc.split(',')
    excs.each do |ex|
      next if ex == ''
      if ex.include?('/')
        if rps.key?(ex)
          puts "Duplicate exception repo entry: #{ex}"
          return
        end
        rps[ex] = true
      else
        if ors.key?(ex)
          puts "Duplicate exception org entry: #{ex}"
          return
        end
        ors[ex] = true
      end
    end
    if ranges.key?(key)
      puts "Duplicate ranges key: #{key}"
      return
    end
    ranges[key] = [min.to_i, max.to_i, ors, rps]
  end

  # Repo --> Project mapping
  projects = {}
  CSV.foreach(fhint, headers: true) do |row|
    h = row.to_h
    proj = (h['project'] || '').strip
    repo = (h['repo'] || '').strip
    if proj == '' || repo == ''
      puts "Invalid hint: project='#{proj}' repo='#{repo}'"
      return
    end
    if projects.key?(repo)
      if projects[repo] != proj
        puts "Non unique entry: projects: projects['#{repo}'] = '#{projects[repo]}', new value: #{proj}"
      else
        puts "Duplicate entry: projects: projects['#{repo}'] = '#{projects[repo]}'"
      end
      return
    end
    projects[repo] = proj
  end

  # Sort hints files on the fly (program user manually updates that file while working so it should be sorted all the time)
  hdr = ['repo', 'project']
  CSV.open(fhint, "w", headers: hdr) do |csv|
    csv << hdr
    projects.keys.sort.each do |repo|
      csv << [repo, projects[repo]]
    end
  end

  # Project --> URL mapping (it uses final project name after all mappings, including defmaps.csv)
  urls = {}
  CSV.foreach(furls, headers: true) do |row|
    h = row.to_h
    proj = (h['project'] || '').strip
    url = (h['url'] || '').strip
    if proj == '' || url == ''
      puts "Invalid URL: project='#{proj}' url='#{url}'"
      return
    end
    if urls.key?(proj)
      if urls[proj] != url
        puts "Non unique entry: urls: urls['#{proj}'] = '#{urls[proj]}', new value: #{url}"
      else
        puts "Duplicate entry: urls: urls['#{proj}'] = '#{urls[proj]}'"
      end
      return
    end
    urls[proj] = url
  end

  # Sort URLs files on the fly (program user manually updates that file while working so it should be sorted all the time)
  hdr = ['project', 'url']
  CSV.open(furls, "w", headers: hdr) do |csv|
    csv << hdr
    urls.keys.sort.each do |project|
      csv << [project, urls[project]]
    end
  end

  # Final name --> new name mapping (defmaps)
  # Used to create better names for projects auto generated just from org or repo name
  # And/Or to group multiple orgs, repos, projects or combinations of all into single project
  # For example we can create "XYZ" forject for sum of "Kubernetes" and "dotnet" via:
  # name,project
  # Kubernetes,XYZ
  # dotnet,XYZ
  defmaps = {}
  CSV.foreach(fdefmaps, headers: true) do |row|
    h = row.to_h
    name = (h['name'] || '').strip
    project = (h['project'] || '').strip
    if project == '' || name == ''
      puts "Invalid defmap: project='#{project}' name='#{name}'"
      return
    end
    if defmaps.key?(name)
      if defmaps[name] != project
        puts "Non unique entry: defmaps: defmaps['#{name}'] = '#{defmaps[name]}', new value: #{project}"
      else
        puts "Duplicate entry: defmaps: defmaps['#{name}'] = '#{defmaps[name]}'"
      end
      return
    end
    defmaps[name] = project
  end

  # Sort defmaps files on the fly (program user manually updates that file while working so it should be sorted all the time)
  hdr = ['name', 'project']
  CSV.open(fdefmaps, "w", headers: hdr) do |csv|
    csv << hdr
    defmaps.keys.sort.each do |name|
      csv << [name, defmaps[name]]
    end
  end

  # Missing URLs: will abort program: if somebody care to define some project (via hints, defmaps or whatever) then let's force him/her to define project URL as well
  # This won't complain about autogenerated projects (like sum of org repos etc)
  urls_found = true
  projects.values.uniq.each do |project|
    unless urls.key? project
      puts "Project '#{project}' have no URL defined, aborting"
      urls_found = false
    end
  end
  defmaps.values.uniq.each do |project|
    unless urls.key? project
      puts "Defmap Project '#{project}' have no URL defined, aborting"
      urls_found = false
    end
  end
  return unless urls_found

  # Analysis:
  # Get repo name from CSV row
  # If repo found in projects set mode to "project" and groupping
  # If project not found and "org" is present set mode to "org" and groupping
  # If mode not determined yet set it to repo
  # Now check if final project key (project, org or repo) is in additional mapping
  # Additional mapping is used to:
  # create better name for data groupped by org (when default is enough) like org = "aspnet" --> ASP.net
  # group multiple orgs and orgs with repos into single project
  orgs = {}
  project_counts = {}
  all_repos = {}
  CSV.foreach(fin, headers: true) do |row|
    h = row.to_h

    # skip repos & orgs
    repo = h['repo']
    all_repos[repo] = true
    next if skip_repos.key? repo
    org = h['org']
    next if skip_orgs.key? org

    # skip by values ranges
    skip = false
    ranges.each do |key, value|
      min_v, max_v, ors, rps = *value
      next if ors.key? org
      next if rps.key? repo

      unless key == 'authors'
        v = h[key].to_i
      else
        v = h[key].split(',').uniq.count
      end
      if min_v > 0 && v < min_v
        skip = true
        break
      end
      if max_v > 0 && v > max_v
        skip = true
        break
      end
    end
    next if skip

    k = h['project'] = projects[repo]
    mode = nil
    if k
      project_counts[k] = [0, []] unless project_counts.key?(k)
      project_counts[k][0] += 1
      project_counts[k][1] << repo
      mode = 'project'
    end
    k = org unless k
    mode = 'org' if k &&!mode
    k = h['repo'] unless k
    next unless k
    mode = 'repo' unless mode
    if defmaps.key? k
      k = defmaps[k]
      mode = 'defmap'
    end
    h['project'] = k
    h['mode'] = mode
    next if skip_projs.key?(k)

    orgs[k] = { items: [] } unless orgs.key? k
    h.each do |p, v|
      vi = v.to_i
      vis = vi.to_s
      h[p] = vi if vis == v
    end
    orgs[k][:items] << h
  end

  orgs.each do |name, org|
    org[:sum] = {}
    org[:items].each do |repo|
      repo.each do |k, v|
        if ['authors', 'authors_alt1'].include? k
          if org[:sum].key? k
            org[:sum][k] += ',' + v.to_s
          else
            org[:sum][k] = v.to_s
          end
          next
        end
        if v.is_a?(String)
          if repo['org'] && k == 'repo' && v.include?('/')
            v = v.split('/')[1]
          end
          if org[:sum].key? k
            org[:sum][k] = '' if org[:sum][k].nil?
            org[:sum][k] += '+' + v
          else
            org[:sum][k] = v 
          end
        elsif v.is_a?(Integer)
          org[:sum][k] = 0 unless org[:sum].key? k
          org[:sum][k] += v
        else
          org[:sum][k] = nil
        end
      end
    end
    new_org = org[:sum]['org'].to_s
    org[:sum]['org'] = new_org.split('+').uniq.join('+') if new_org
    new_prj = org[:sum]['project'].to_s
    org[:sum]['project'] = new_prj.split('+').uniq.join('+') if new_prj
    new_mode = org[:sum]['mode']
    org[:sum]['mode'] = new_mode.split('+').uniq.join('+') if new_mode
    org[:sum]['authors'] = org[:sum]['authors'].split(',').uniq.count
    if org[:sum]['authors'] < 1
      puts "WARNING: data from BigQuery truncated, no authors on current org: #{org[:sum]['project']}"
      alt1 = org[:sum]['authors_alt1'].split(',').uniq.count
      if alt1 > 1
        puts "Alternate value used: #{alt1}"
        org[:sum]['authors'] = alt1
      else
        puts "Very Alternate value used: #{org[:sum]['authors_alt2']}"
        org[:sum]['authors'] = org[:sum]['authors_alt2']
      end
      binding.pry
    end
  end

  # Sort by sort_col desc to get list of top projects
  orgs_arr = []
  orgs.each do |name, org|
    orgs_arr << [name, org[:sum][sort_col], org]
  end

  res = orgs_arr.sort_by { |item| -item[1] }

  # now create list of projects missing URL (`miss` variable to be seen in debugger)
  # but only display and stop in debugger if any missing URL in top 50
  # so if no URL is missing in Top 50 projects, it won't stop at this point, but missing URLs
  # for projects >50th will still be in `miss` variable
  no_url = false
  miss = []
  unmapped = {}
  ract = {}
  rcomm = {}
  rauth = {}
  res.each_with_index do |item, index|
    sum = item[2][:sum]
    project = sum['project']
    # ract[project] = item[2][:items].map { |i| [i['activity'], i['repo']] }.sort_by { |i| -i[0] }.map { |i| ("%-8d" % i[0]) + " #{i[1]}" }
    ract[project] = item[2][:items].map { |i| [i['activity'], i['repo']] }.sort_by { |i| -i[0] }.map { |i| "#{i[1]},#{i[0]}" }
    rcomm[project] = item[2][:items].map { |i| [i['commits'], i['repo']] }.sort_by { |i| -i[0] }.map { |i| "#{i[1]},#{i[0]}" }
    rauth[project] = item[2][:items].map { |i| [i['authors'].split(',').count, i['repo']] }.sort_by { |i| -i[0] }.map { |i| "#{i[1]},#{i[0]}" }
    if !urls.key?(project)
      s = "Project ##{index} (#{sum['mode']}, #{sum[sort_col]}) #{project} (#{sum['org']}) (#{sum['repo']}) have no URL defined"
      if index <= 50
        unmapped[project] = item[2][:items].map { |i| [i['activity'], i['repo']] }.sort_by { |i| -i[0] }.map { |i| ("%-8d" % i[0]) + " #{i[1]}" }
        puts s
        no_url = true
      end
      miss << s
      sum['url'] = ''
    else
      sum['url'] = urls[project]
    end
  end
  puts "Use `unmapped` to see what needs to be defined" if no_url
  binding.pry if no_url

  puts 'res[0..30].map { |it| it[0] }'
  puts "Defined projects: "
  prjs = []
  project_counts.keys.sort.each do |k|
    prjs << "#{k}: #{project_counts[k][0]}"
  end
  prjs = prjs.join(', ')
  puts prjs

  # This is pretty print of what was found, it is displayed and program stops in debugger
  # To see all projects use `all variable` if ok type "quit" to exit debugger and save results
  puts "Top:"
  tops = res[0..40].map.with_index { |it, idx| "#{idx}) #{it[0]} (#{it[2][:sum]['mode']} #{it[2][:sum]['url']}): #{it[1]} (#{it[2][:sum]['org']}) (#{it[2][:sum]['repo']})" }
  all = res.map.with_index { |it, idx| "#{idx}) #{it[0]} (#{it[2][:sum]['mode']} #{it[2][:sum]['url']}): #{it[1]} (#{it[2][:sum]['org']}) (#{it[2][:sum]['repo']})" }
  puts tops
  puts "`all` to see all data, `miss` to see missing project's urls, `ract['key'] to see `key`'s repos sorted by activity desc (also rcomm, rauth for commits and authors)"
  puts "Use `rauth[res[N][0]]` to examine what creates N-th top project, actually to have a good Top N data, You should define all data correctly for 0-N"
  puts "Or by project name `rauth[res[res.map { |i| i[0] }.index('project_name')][0]]`"
  puts "Project's index is: `res.map { |i| i[0] }.index('project_name')`, top N: `res.map { |i| i[0] }[0..N]`"
  puts "List of 'Google' repos that have > 10 authors: `rauth[res[res.map { |i| i[0] }.index('Google')][0]].select { |i| i.split(',')[1].to_i > 10 }.map { |i| i.split(',')[0] }.join(',')`"
  puts "See indices of projects contain something in name: `res.map.with_index { |e, i| [e, i] }.select { |e| e[0][0].include?('OpenStack') }.map { |e| \"\#{e[1]} \#{e[0][0]}\" }`"
  puts "Nice view Top 50: `res.map.with_index { |e,i| \"\#{i+1} \#{e[0]}\" }[0..49]`"
  puts "Dan loves it: `res[res.map { |i| i[0] }.index('Google Cloud')][2][:items].map { |i| [i['repo'], i['commits'], i['issues'], i['prs'], i['authors'].split(',').count] }.sort_by { |i| -i[1] }.map { |i| \"\#{i[0]}, commits: \#{i[1]}, issues: \#{i[2]}, PRs: \#{i[3]}, authors: \#{i[4]}\" }`"

  binding.pry

  ks = res[0][2][:sum].keys - %w(mode authors_alt1 authors_alt2)
  CSV.open(fout, "w", headers: ks) do |csv|
    csv << ks
    res.each do |row|
      csv_row = []
      ks.each do |key|
        csv_row << row[2][:sum][key]
      end
      csv << csv_row
    end
  end

  CSV.open('all_repos.csv', "w", headers: ['repo']) do |csv|
    csv << ['repo']
    all_repos.keys.sort.each do |repo|
      csv << [repo]
    end
  end
end

if ARGV.size < 7
  puts "Missing arguments: input_data.csv output_projects.csv hints.csv urls.csv defmaps.csv skip.csv ranges.csv"
  exit(1)
end

analysis(ARGV[0], ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5], ARGV[6])

