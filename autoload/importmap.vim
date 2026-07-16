" core dispatcher, completion, and command orchestration
scriptencoding utf-8

let s:save_cpo = &cpo
set cpo&vim

function! importmap#ParseSpec(str) abort
  let l:at_idx = strridx(a:str, '@')
  if l:at_idx > 0
    let l:name = a:str[: l:at_idx - 1]
    let l:spec = a:str[l:at_idx + 1 :]
    if empty(l:spec)
      let l:spec = 'latest'
    endif
  else
    let l:name = a:str
    let l:spec = 'latest'
  endif
  if l:name =~# '/' && l:name !~# '^@[^/]\+/[^/]\+$'
    throw 'importmap.vim: subpath install (' . l:name . ') not supported; prefix mapping makes subpaths importable'
  endif
  return {'name': l:name, 'spec': l:spec}
endfunction

" the punchline prints after the install finishes, so it is the message
" left hanging on the screen instead of being overwritten a moment later
function! importmap#Bower(args, bang) abort
  if !empty(a:args) && (a:args[0] ==# 'install' || a:args[0] ==# 'add' || a:args[0] ==# 'i')
    let s:bower_nostalgia = 1
  endif
  call importmap#Dispatch(a:args, a:bang)
endfunction

" route an exception through the user-facing error channel; async job
" callbacks run long after Dispatch's try/catch has returned, so they need
" the same treatment applied locally
function! s:Rescue(exception) abort
  let s:bower_nostalgia = 0
  if a:exception =~# '^importmap\.vim:'
    call importmap#util#Error(substitute(a:exception, '^importmap\.vim:\s*', '', ''))
  else
    call importmap#util#Error('internal error: ' . a:exception . ' (run :ImportMap doctor)')
  endif
endfunction

function! importmap#Dispatch(args, bang) abort
  try
    if empty(a:args)
      call s:CmdList()
      return
    endif
    let l:cmd = a:args[0]
    let l:subargs = a:args[1 :]
    if l:cmd ==# 'install' || l:cmd ==# 'add' || l:cmd ==# 'i'
      call importmap#Install(l:subargs, a:bang)
    elseif l:cmd ==# 'rm' || l:cmd ==# 'remove' || l:cmd ==# 'uninstall'
      call s:CmdRm(l:subargs)
    elseif l:cmd ==# 'update' || l:cmd ==# 'up'
      call s:CmdUpdate(l:subargs, a:bang)
    elseif l:cmd ==# 'outdated'
      call s:CmdOutdated(l:subargs, a:bang)
    elseif l:cmd ==# 'list' || l:cmd ==# 'ls'
      call s:CmdList()
    elseif l:cmd ==# 'sync'
      call importmap#scan#Sync(a:bang)
    elseif l:cmd ==# 'integrity'
      call importmap#integrity#Run(a:bang)
    elseif l:cmd ==# 'cdn'
      call s:CmdCdn(l:subargs)
    elseif l:cmd ==# 'doctor'
      call s:CmdDoctor()
    else
      throw 'importmap.vim: unknown subcommand: ' . l:cmd . ' (see :help :ImportMap)'
    endif
  catch
    call s:Rescue(v:exception)
  endtry
endfunction

function! importmap#Install(subargs, bang) abort
  if empty(a:subargs)
    throw 'importmap.vim: provide at least one package to install'
  endif

  let l:specs = []
  for l:arg in a:subargs
    call add(l:specs, importmap#ParseSpec(l:arg))
  endfor

  " read now so a bad target fails before any network round trip; the
  " callback re-reads to pick up anything that changed while fetching
  let l:target = importmap#html#LocateTarget()
  call importmap#html#ReadMap(l:target)

  call importmap#job#Latch(l:specs, 8, function('s:FetchWorker', [a:bang]), function('s:OnInstallAllFetched', [l:specs, l:target]))
endfunction

function! s:FetchWorker(bang, item, on_done) abort
  call importmap#registry#GetMetadata(a:item.name, a:bang, a:on_done)
endfunction

function! s:OnInstallAllFetched(specs, target, results) abort
  try
    let l:map_meta = importmap#html#ReadMap(a:target)
    let l:map_dict = copy(l:map_meta.parsed)

    if !has_key(l:map_dict, 'imports') || type(l:map_dict.imports) !=# type({})
      let l:map_dict.imports = {}
    endif

    let l:msgs = []
    for l:spec in a:specs
      let l:doc = get(a:results, l:spec.name, v:null)
      if type(l:doc) !=# type({})
        call importmap#util#Error('failed to fetch metadata for ' . l:spec.name . ' (skipped)')
        continue
      endif

      let l:dist_tags = get(l:doc, 'dist-tags', {})
      let l:versions = get(l:doc, 'versions', {})
      if type(l:dist_tags) !=# type({})
        let l:dist_tags = {}
      endif
      if type(l:versions) !=# type({})
        let l:versions = {}
      endif
      " one package failing to resolve must not take the batch down with it
      try
        if has_key(l:dist_tags, l:spec.spec)
          let l:ver = l:dist_tags[l:spec.spec]
        else
          let l:ver = importmap#semver#MaxSatisfying(keys(l:versions), l:spec.spec)
        endif
      catch /^importmap\.vim:/
        call importmap#util#Error(substitute(v:exception, '^importmap\.vim:\s*', '', '') . ' (skipped ' . l:spec.name . ')')
        continue
      endtry

      if empty(l:ver)
        call importmap#util#Error('no satisfying version found for ' . l:spec.name . '@' . l:spec.spec . ' (skipped)')
        continue
      endif

      let l:urls = importmap#cdn#Urls(g:importmap_cdn, l:spec.name, l:ver)
      let l:old_url = get(l:map_dict.imports, l:spec.name, '')

      let l:map_dict.imports[l:spec.name] = l:urls.bare
      if g:importmap_prefix_mappings
        let l:map_dict.imports[l:spec.name . '/'] = l:urls.prefix
      endif

      if !empty(l:old_url) && l:old_url !=# l:urls.bare && has_key(get(l:map_dict, 'integrity', {}), l:old_url)
        call remove(l:map_dict.integrity, l:old_url)
      endif

      if empty(l:old_url)
        call add(l:msgs, '+ ' . l:spec.name . '@' . l:ver . ' (' . g:importmap_cdn . ')')
      elseif l:old_url ==# l:urls.bare
        call add(l:msgs, '= ' . l:spec.name . '@' . l:ver . ' (unchanged)')
      else
        call add(l:msgs, '^ ' . l:spec.name . ' to ' . l:ver . ' (' . g:importmap_cdn . ')')
      endif
    endfor

    call importmap#html#WriteMap(l:map_meta.path, l:map_dict, l:map_meta)

    for l:msg in l:msgs
      call importmap#util#Info(l:msg)
    endfor
    if len(l:msgs) > 3
      call importmap#util#Info('Updated ' . len(l:msgs) . ' packages in ' . l:map_meta.path)
    endif
    if get(s:, 'bower_nostalgia', 0)
      let s:bower_nostalgia = 0
      echomsg "importmap.vim: it's been a long decade, hasn't it"
    endif
  catch
    call s:Rescue(v:exception)
  endtry
endfunction

function! s:CmdRm(subargs) abort
  if empty(a:subargs)
    throw 'importmap.vim: provide at least one package to remove'
  endif

  let l:target = importmap#html#LocateTarget()
  let l:map_meta = importmap#html#ReadMap(l:target)
  let l:map_dict = copy(l:map_meta.parsed)
  let l:imports = get(l:map_dict, 'imports', {})
  let l:integrity = get(l:map_dict, 'integrity', {})

  for l:pkg in a:subargs
    let l:removed = 0
    if has_key(l:imports, l:pkg)
      let l:old_url = l:imports[l:pkg]
      if has_key(l:integrity, l:old_url) | call remove(l:integrity, l:old_url) | endif
      call remove(l:imports, l:pkg)
      let l:removed = 1
    endif
    if has_key(l:imports, l:pkg . '/')
      let l:old_p = l:imports[l:pkg . '/']
      if has_key(l:integrity, l:old_p) | call remove(l:integrity, l:old_p) | endif
      call remove(l:imports, l:pkg . '/')
      let l:removed = 1
    endif
    if l:removed
      call importmap#util#Info('- ' . l:pkg)
    else
      call importmap#util#Warn('package not found in map: ' . l:pkg)
    endif
  endfor

  call importmap#html#WriteMap(l:map_meta.path, l:map_dict, l:map_meta)
endfunction

function! s:CmdUpdate(subargs, bang) abort
  let l:target = importmap#html#LocateTarget()
  let l:map_meta = importmap#html#ReadMap(l:target)
  let l:imports = get(l:map_meta.parsed, 'imports', {})

  let l:pkgs_to_update = []
  if empty(a:subargs)
    for l:k in keys(l:imports)
      if l:k !~# '/$'
        call add(l:pkgs_to_update, l:k)
      endif
    endfor
    if empty(l:pkgs_to_update)
      call importmap#util#Info('no packages in import map')
      return
    endif
  else
    let l:pkgs_to_update = copy(a:subargs)
  endif

  let l:install_specs = []
  for l:arg in l:pkgs_to_update
    let l:s = importmap#ParseSpec(l:arg)
    if !has_key(l:imports, l:s.name)
      call importmap#util#Warn('package not found in map: ' . l:s.name)
      continue
    endif
    if l:arg !~# '@[^/]\+$' || (l:s.spec ==# 'latest' && l:arg !~# '@latest$')
      let l:purl = importmap#cdn#ParseUrl(l:imports[l:s.name])
      if get(l:purl, 'valid', v:false) && !empty(get(l:purl, 'version', ''))
        let l:clean_ver = substitute(l:purl.version, '^[~^]\+', '', '')
        let l:s.spec = '^' . l:clean_ver
      endif
    endif
    call add(l:install_specs, l:s.name . '@' . l:s.spec)
  endfor

  if empty(l:install_specs)
    return
  endif
  call importmap#Install(l:install_specs, a:bang)
endfunction

function! s:CmdOutdated(subargs, bang) abort
  let l:target = importmap#html#LocateTarget()
  let l:map_meta = importmap#html#ReadMap(l:target)
  let l:imports = get(l:map_meta.parsed, 'imports', {})
  let l:pkgs = filter(copy(keys(l:imports)), 'v:val !~# "/$"')
  if !empty(a:subargs)
    call filter(l:pkgs, 'index(a:subargs, v:val) >= 0')
  endif
  if empty(l:pkgs)
    call importmap#util#Info('no packages in import map')
    return
  endif

  let l:specs = map(copy(l:pkgs), '{"name": v:val, "spec": "latest"}')
  call importmap#job#Latch(l:specs, 8, function('s:FetchWorker', [a:bang]), function('s:OnOutdatedFetched', [l:pkgs, l:map_meta, l:imports]))
endfunction

" line of the mapping for this package inside the block, for quickfix
function! s:MappingLine(map_meta, pkg) abort
  if a:map_meta.start_line < 1
    return 1
  endif
  let l:i = a:map_meta.start_line - 1
  let l:last = min([a:map_meta.end_line, len(a:map_meta.raw_lines)])
  while l:i < l:last
    if stridx(a:map_meta.raw_lines[l:i], '"' . a:pkg . '"') != -1
      return l:i + 1
    endif
    let l:i += 1
  endwhile
  return a:map_meta.start_line
endfunction

function! s:OnOutdatedFetched(pkgs, map_meta, imports, results) abort
  try
    let l:qf = []
    call importmap#util#Info(printf('%-30s %-15s %-15s %-15s', 'Package', 'Current', 'Wanted', 'Latest'))
    for l:pkg in sort(copy(a:pkgs), 'importmap#mapfile#CompareKeys')
      let l:purl = importmap#cdn#ParseUrl(a:imports[l:pkg])
      let l:cur = get(l:purl, 'version', 'unknown')
      let l:clean_cur = substitute(l:cur, '^[~^]\+', '', '')
      let l:doc = get(a:results, l:pkg, v:null)
      if type(l:doc) !=# type({})
        call importmap#util#Warn('failed to check outdated for ' . l:pkg)
        continue
      endif
      let l:versions = get(l:doc, 'versions', {})
      let l:dist_tags = get(l:doc, 'dist-tags', {})
      if type(l:versions) !=# type({})
        let l:versions = {}
      endif
      if type(l:dist_tags) !=# type({})
        let l:dist_tags = {}
      endif
      let l:wanted = importmap#semver#MaxSatisfying(keys(l:versions), '^' . l:clean_cur)
      let l:latest = get(l:dist_tags, 'latest', '')
      if l:clean_cur !=# l:latest || l:clean_cur !=# l:wanted
        call importmap#util#Info(printf('%-30s %-15s %-15s %-15s', l:pkg, l:cur, l:wanted, l:latest))
        call add(l:qf, {'filename': a:map_meta.path, 'lnum': s:MappingLine(a:map_meta, l:pkg), 'text': printf('%s: current %s, wanted %s, latest %s', l:pkg, l:cur, l:wanted, l:latest)})
      endif
    endfor

    if !empty(l:qf)
      call setqflist(l:qf)
      call importmap#util#Info(len(l:qf) . ' outdated package(s) loaded into quickfix list (:copen / :cnext)')
    else
      call importmap#util#Info('all packages are up to date')
    endif
  catch
    call s:Rescue(v:exception)
  endtry
endfunction

function! s:CmdList() abort
  let l:target = importmap#html#LocateTarget()
  let l:map_meta = importmap#html#ReadMap(l:target)
  let l:imports = get(l:map_meta.parsed, 'imports', {})
  let l:pkgs = sort(filter(copy(keys(l:imports)), 'v:val !~# "/$"'), 'importmap#mapfile#CompareKeys')
  if empty(l:pkgs)
    call importmap#util#Info('import map is empty')
    return
  endif
  call importmap#util#Info(printf('%-35s %-15s %s', 'Package', 'Version', 'CDN'))
  for l:pkg in l:pkgs
    let l:purl = importmap#cdn#ParseUrl(l:imports[l:pkg])
    let l:ver = get(l:purl, 'version', '')
    let l:cdn = get(l:purl, 'provider', 'custom')
    call importmap#util#Info(printf('%-35s %-15s %s', l:pkg, l:ver, l:cdn))
  endfor
endfunction

function! s:CmdCdn(subargs) abort
  if empty(a:subargs)
    throw 'importmap.vim: specify target CDN: esm.sh, jsdelivr, or unpkg'
  endif
  let l:target_cdn = a:subargs[0]
  if index(['esm.sh', 'jsdelivr', 'unpkg'], l:target_cdn) == -1
    throw 'importmap.vim: unknown CDN provider: ' . l:target_cdn . ' (must be esm.sh, jsdelivr, or unpkg)'
  endif

  let l:target = importmap#html#LocateTarget()
  let l:map_meta = importmap#html#ReadMap(l:target)
  let l:map_dict = copy(l:map_meta.parsed)
  let l:imports = get(l:map_dict, 'imports', {})
  let l:integrity = get(l:map_dict, 'integrity', {})
  let l:changed = 0

  for [l:pkg, l:url] in items(l:imports)
    let l:purl = importmap#cdn#ParseUrl(l:url)
    if get(l:purl, 'valid', v:false) && !empty(get(l:purl, 'name', '')) && !empty(get(l:purl, 'version', ''))
      let l:new_urls = importmap#cdn#Urls(l:target_cdn, l:purl.name, l:purl.version)
      let l:new_url = l:pkg =~# '/$' ? l:new_urls.prefix : l:new_urls.bare
      if l:new_url !=# l:url
        if has_key(l:integrity, l:url) | call remove(l:integrity, l:url) | endif
        let l:imports[l:pkg] = l:new_url
        let l:changed += 1
      endif
    endif
  endfor

  if l:changed > 0
    call importmap#html#WriteMap(l:map_meta.path, l:map_dict, l:map_meta)
    call importmap#util#Info('rewrote ' . l:changed . ' mapping(s) onto ' . l:target_cdn . ' (run :ImportMap integrity if using SRI)')
  else
    call importmap#util#Info('no mappings rewritten')
  endif
endfunction

function! s:CmdDoctor() abort
  call importmap#util#Info('=== importmap.vim Doctor ===')
  let l:curl_ok = executable(g:importmap_curl)
  call importmap#util#Info('curl executable: ' . (l:curl_ok ? 'yes (' . g:importmap_curl . ')' : 'NO'))
  let l:ssl_ok = executable(g:importmap_openssl)
  call importmap#util#Info('openssl executable: ' . (l:ssl_ok ? 'yes (' . g:importmap_openssl . ')' : 'NO'))
  call importmap#util#Info('project root: ' . importmap#util#FindRoot())
  try
    let l:target = importmap#html#LocateTarget()
    call importmap#util#Info('target file: ' . l:target)
    let l:map_meta = importmap#html#ReadMap(l:target)
    call importmap#util#Info('importmap block exists: ' . (l:map_meta.found || l:map_meta.is_json_mode ? 'yes' : 'no'))
    call importmap#util#Info('importmap parses cleanly: yes')
  catch
    call importmap#util#Warn('target file error: ' . v:exception)
  endtry
  call importmap#util#Info('cache directory: ' . importmap#util#CacheDir())
  call importmap#util#Info('g:importmap_cdn: ' . g:importmap_cdn)
  call importmap#util#Info('g:importmap_prefix_mappings: ' . g:importmap_prefix_mappings)
  call importmap#util#Info('=== Doctor Report Complete ===')
endfunction

function! importmap#Complete(argLead, cmdLine, cursorPos) abort
  let l:parts = split(a:cmdLine[: a:cursorPos - 1], '\s\+', 1)
  if len(l:parts) <= 2 && a:cmdLine[: a:cursorPos - 1] !~# '\s\+[^ ]\+\s\+'
    let l:cmds = ['install', 'rm', 'update', 'outdated', 'list', 'sync', 'integrity', 'cdn', 'doctor']
    return filter(copy(l:cmds), 'v:val =~# "^" . a:argLead')
  endif

  let l:subcmd = l:parts[1]
  if l:subcmd ==# 'rm' || l:subcmd ==# 'remove' || l:subcmd ==# 'update' || l:subcmd ==# 'up' || l:subcmd ==# 'outdated'
    try
      let l:target = importmap#html#LocateTarget()
      let l:map_meta = importmap#html#ReadMap(l:target)
      let l:imports = get(l:map_meta.parsed, 'imports', {})
      let l:pkgs = filter(copy(keys(l:imports)), 'v:val !~# "/$"')
      return filter(l:pkgs, 'v:val =~# "^" . a:argLead')
    catch
      return []
    endtry
  elseif l:subcmd ==# 'cdn'
    let l:cdns = ['esm.sh', 'jsdelivr', 'unpkg']
    return filter(copy(l:cdns), 'v:val =~# "^" . a:argLead')
  elseif l:subcmd ==# 'install' || l:subcmd ==# 'add' || l:subcmd ==# 'i'
    try
      let l:at_idx = strridx(a:argLead, '@')
      if l:at_idx > 0
        let l:name = a:argLead[: l:at_idx - 1]
        let l:doc = importmap#registry#GetMetadataSync(l:name, 2000)
        if type(l:doc) ==# type({})
          let l:tags = get(l:doc, 'dist-tags', {})
          let l:versions = get(l:doc, 'versions', {})
          if type(l:tags) !=# type({})
            let l:tags = {}
          endif
          if type(l:versions) !=# type({})
            let l:versions = {}
          endif
          let l:vers = reverse(sort(copy(keys(l:versions)), 'importmap#semver#Cmp'))[:15]
          let l:cands = map(keys(l:tags) + l:vers, 'l:name . "@" . v:val')
          return filter(l:cands, 'v:val =~# "^" . a:argLead')
        endif
        return []
      else
        let l:res = importmap#registry#SearchSync(a:argLead, 2000)
        if type(l:res) ==# type({}) && type(get(l:res, 'objects', v:null)) ==# type([])
          let l:names = []
          for l:obj in l:res.objects
            if type(l:obj) ==# type({}) && type(get(l:obj, 'package', v:null)) ==# type({}) && has_key(l:obj.package, 'name')
              call add(l:names, l:obj.package.name)
            endif
          endfor
          return filter(l:names, 'v:val =~# "^" . a:argLead')
        endif
        return []
      endif
    catch
      return []
    endtry
  endif
  return []
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
