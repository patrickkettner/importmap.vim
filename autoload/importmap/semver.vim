" pure vimscript semver parsing, comparison, and range resolution
scriptencoding utf-8

let s:save_cpo = &cpo
set cpo&vim

function! importmap#semver#Parse(str) abort
  let l:clean = substitute(a:str, '^\s*v\?', '', '')
  let l:clean = substitute(l:clean, '+.*$', '', '')
  let l:clean = substitute(l:clean, '^\s*=\s*', '', '')

  let l:invalid = {'major': 0, 'minor': 0, 'patch': 0, 'prerelease': [], 'valid': 0}

  let l:dash_idx = stridx(l:clean, '-')
  if l:dash_idx != -1
    let l:ver_part = l:clean[: l:dash_idx - 1]
    let l:pre_part = l:clean[l:dash_idx + 1 :]
    if empty(l:pre_part)
      return l:invalid
    endif
  else
    let l:ver_part = l:clean
    let l:pre_part = ''
  endif

  let l:nums = split(l:ver_part, '\.', 1)
  if len(l:nums) != 3
    return l:invalid
  endif
  for l:num in l:nums
    if l:num !~# '^\%(0\|[1-9]\d*\)$'
      return l:invalid
    endif
  endfor

  let l:prerelease = []
  if !empty(l:pre_part)
    for l:id in split(l:pre_part, '\.', 1)
      if empty(l:id)
        return l:invalid
      endif
      call add(l:prerelease, l:id =~# '^\%(0\|[1-9]\d*\)$' ? str2nr(l:id, 10) : l:id)
    endfor
  endif

  return {'major': str2nr(l:nums[0], 10), 'minor': str2nr(l:nums[1], 10), 'patch': str2nr(l:nums[2], 10), 'prerelease': l:prerelease, 'valid': 1}
endfunction

function! importmap#semver#Cmp(a, b) abort
  let l:pa = type(a:a) ==# type({}) ? a:a : importmap#semver#Parse(a:a)
  let l:pb = type(a:b) ==# type({}) ? a:b : importmap#semver#Parse(a:b)

  if !l:pa.valid && !l:pb.valid
    return 0
  elseif !l:pa.valid
    return -1
  elseif !l:pb.valid
    return 1
  endif

  if l:pa.major != l:pb.major
    return l:pa.major < l:pb.major ? -1 : 1
  endif
  if l:pa.minor != l:pb.minor
    return l:pa.minor < l:pb.minor ? -1 : 1
  endif
  if l:pa.patch != l:pb.patch
    return l:pa.patch < l:pb.patch ? -1 : 1
  endif

  if empty(l:pa.prerelease) && empty(l:pb.prerelease)
    return 0
  elseif !empty(l:pa.prerelease) && empty(l:pb.prerelease)
    return -1
  elseif empty(l:pa.prerelease) && !empty(l:pb.prerelease)
    return 1
  endif

  let l:max_len = max([len(l:pa.prerelease), len(l:pb.prerelease)])
  let l:i = 0
  while l:i < l:max_len
    if l:i >= len(l:pa.prerelease)
      return -1
    elseif l:i >= len(l:pb.prerelease)
      return 1
    endif

    let l:ida = l:pa.prerelease[l:i]
    let l:idb = l:pb.prerelease[l:i]
    let l:num_a = l:ida =~# '^\d\+$'
    let l:num_b = l:idb =~# '^\d\+$'

    if l:num_a && l:num_b
      let l:na = str2nr(l:ida, 10)
      let l:nb = str2nr(l:idb, 10)
      if l:na != l:nb
        return l:na < l:nb ? -1 : 1
      endif
    elseif l:num_a && !l:num_b
      return -1
    elseif !l:num_a && l:num_b
      return 1
    else
      if l:ida !=# l:idb
        return l:ida <# l:idb ? -1 : 1
      endif
    endif
    let l:i += 1
  endwhile
  return 0
endfunction

function! importmap#semver#MaxSatisfying(versions_list, range) abort
  let l:range = trim(a:range)
  if l:range =~# '[<>|]' || l:range =~# '\s-\s'
    throw 'importmap.vim: unsupported version range: ' . l:range . ' (use an exact version, ^, ~, or x ranges)'
  endif

  " a prerelease version only satisfies a range whose own comparator is a
  " prerelease of the same major.minor.patch, matching npm
  let l:range_pre = importmap#semver#Parse(substitute(l:range, '^\s*[~^]\s*', '', ''))
  let l:range_has_pre = l:range_pre.valid && !empty(l:range_pre.prerelease)

  let l:candidates = []
  for l:ver in a:versions_list
    let l:pv = importmap#semver#Parse(l:ver)
    if !l:pv.valid
      continue
    endif
    if !empty(l:pv.prerelease) && l:range !=# l:ver
      if !l:range_has_pre
        continue
      endif
      if [l:pv.major, l:pv.minor, l:pv.patch] != [l:range_pre.major, l:range_pre.minor, l:range_pre.patch]
        continue
      endif
    endif
    if s:Satisfies(l:pv, l:range)
      call add(l:candidates, l:ver)
    endif
  endfor

  if empty(l:candidates)
    return ''
  endif
  call sort(l:candidates, 'importmap#semver#Cmp')
  return l:candidates[-1]
endfunction

function! s:Satisfies(pv, range) abort
  if empty(a:range) || a:range ==# '*' || a:range ==# 'latest'
    return 1
  endif

  let l:clean = substitute(a:range, '^\s*=\?\s*v\?', '', '')

  " Caret range: ^X.Y.Z
  if a:range =~# '^\s*\^\s*v\?'
    let l:r = substitute(a:range, '^\s*\^\s*v\?', '', '')
    let l:pr = importmap#semver#Parse(l:r)
    if !l:pr.valid
      let l:nums = split(substitute(l:r, '-.*$', '', ''), '\.', 1)
      if len(l:nums) == 1 && l:nums[0] =~# '^\d\+$'
        let l:pr = {'major': str2nr(l:nums[0], 10), 'minor': 0, 'patch': 0, 'prerelease': [], 'valid': 1}
      elseif len(l:nums) == 2 && l:nums[0] =~# '^\d\+$' && l:nums[1] =~# '^\d\+$'
        let l:pr = {'major': str2nr(l:nums[0], 10), 'minor': str2nr(l:nums[1], 10), 'patch': 0, 'prerelease': [], 'valid': 1}
      else
        return 0
      endif
    endif

    if importmap#semver#Cmp(a:pv, l:pr) < 0
      return 0
    endif

    if l:pr.major != 0
      return a:pv.major == l:pr.major
    elseif l:pr.minor != 0
      return a:pv.major == 0 && a:pv.minor == l:pr.minor
    else
      " ^0.0.X or ^0.0
      let l:nums = split(substitute(l:r, '-.*$', '', ''), '\.', 1)
      if len(l:nums) >= 3
        return a:pv.major == 0 && a:pv.minor == 0 && a:pv.patch == l:pr.patch
      elseif len(l:nums) == 2
        return a:pv.major == 0 && a:pv.minor == 0
      else
        return a:pv.major == 0
      endif
    endif

  " Tilde range: ~X.Y.Z
  elseif a:range =~# '^\s*\~\s*v\?'
    let l:r = substitute(a:range, '^\s*\~\s*v\?', '', '')
    let l:pr = importmap#semver#Parse(l:r)
    let l:nums = split(substitute(l:r, '-.*$', '', ''), '\.', 1)
    if !l:pr.valid
      if len(l:nums) == 1 && l:nums[0] =~# '^\d\+$'
        return a:pv.major == str2nr(l:nums[0], 10)
      elseif len(l:nums) == 2 && l:nums[0] =~# '^\d\+$' && l:nums[1] =~# '^\d\+$'
        let l:pr = {'major': str2nr(l:nums[0], 10), 'minor': str2nr(l:nums[1], 10), 'patch': 0, 'prerelease': [], 'valid': 1}
      else
        return 0
      endif
    endif

    if importmap#semver#Cmp(a:pv, l:pr) < 0
      return 0
    endif

    if len(l:nums) >= 2
      return a:pv.major == l:pr.major && a:pv.minor == l:pr.minor
    else
      return a:pv.major == l:pr.major
    endif

  " Partial / wildcard ranges: 1.x, 1.*, 1
  elseif a:range =~# '^\d\+\(\.\d\+\)\?$' || a:range =~# '\.[xX*]$'
    let l:r_clean = substitute(a:range, '\.[xX*]', '', 'g')
    let l:nums = split(l:r_clean, '\.', 1)
    if len(l:nums) == 1
      return a:pv.major == str2nr(l:nums[0], 10)
    elseif len(l:nums) == 2
      return a:pv.major == str2nr(l:nums[0], 10) && a:pv.minor == str2nr(l:nums[1], 10)
    endif
    return 0

  " Exact range
  else
    let l:pr = importmap#semver#Parse(l:clean)
    if !l:pr.valid
      return 0
    endif
    return importmap#semver#Cmp(a:pv, l:pr) == 0
  endif
endfunction

let &cpo = s:save_cpo
unlet s:save_cpo
