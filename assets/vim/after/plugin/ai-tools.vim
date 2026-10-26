if exists('g:loaded_vim_tools_ai_tools')
  finish
endif
let g:loaded_vim_tools_ai_tools = 1

let s:provider = get(g:, 'vim_tools_ai_provider', 'copilot')
let s:cli = s:provider ==# 'fm' && has('macunix') && executable('/usr/bin/fm')
      \ ? '/usr/bin/fm' : exepath(s:provider)
if empty(s:cli)
  let s:cli = s:provider
endif
let s:request = {}
let s:job = 0
let s:fm_server = 0
let s:fm_port = 30000 + getpid() % 20000
let s:ghost = ''
let s:auto_timer = -1
let s:auto_rerun = 0
let s:accepted_ghost = ''
let s:tab_fallback = get(s:, 'tab_fallback', "\<Tab>")
highlight default link VimToolsAICompletion Comment

function! s:JobRunning() abort
  return type(s:job) == v:t_job && job_status(s:job) ==# 'run'
endfunction

function! s:FMServerRunning() abort
  return type(s:fm_server) == v:t_job && job_status(s:fm_server) ==# 'run'
endfunction

function! s:StartFMServer() abort
  if s:provider !=# 'fm' || !executable(s:cli)
    return 0
  endif
  if s:FMServerRunning()
    return 1
  endif
  let s:fm_server = job_start([s:cli, 'serve', '--host', '127.0.0.1',
        \ '--port', string(s:fm_port)],
        \ {'in_io': 'null', 'out_io': 'null', 'err_io': 'null', 'stoponexit': 'term'})
  return s:FMServerRunning()
endfunction

function! s:StopFMServer() abort
  if s:FMServerRunning()
    call job_stop(s:fm_server, 'term')
  endif
  let s:fm_server = 0
endfunction

function! s:StopAutoTimer() abort
  if s:auto_timer != -1
    call timer_stop(s:auto_timer)
    let s:auto_timer = -1
  endif
endfunction

function! s:ClearGhost() abort
  let s:ghost = ''
  if exists('*prop_remove') && exists('*prop_type_get')
        \ && !empty(prop_type_get('VimToolsAICompletion'))
    silent! call prop_remove({'type': 'VimToolsAICompletion', 'all': 1})
  endif
endfunction

function! s:ScheduleCompletion() abort
  if !exists('*timer_start') || &buftype !=# ''
    return
  endif
  if s:auto_timer != -1
    call timer_stop(s:auto_timer)
  endif
  let s:auto_timer = timer_start(1200, function('s:AutoComplete'))
endfunction

function! s:AutoComplete(timer) abort
  let s:auto_timer = -1
  if s:JobRunning()
    let l:request_matches = bufnr('%') == get(s:request, 'buffer', -1)
          \ && line('.') == get(s:request, 'line', -1)
          \ && col('.') == get(s:request, 'column', -1)
          \ && b:changedtick == get(s:request, 'changedtick', -1)
          \ && strpart(getline('.'), 0, col('.') - 1) ==# get(s:request, 'prefix', '')
    if get(s:request, 'kind', '') !=# 'auto_complete' || !l:request_matches
      let s:auto_rerun = 1
    endif
    return
  elseif mode() =~# '^i'
    call s:StartCompletion('auto_complete')
  endif
endfunction

function! s:ShowSuggestion(text) abort
  call s:ClearGhost()
  if exists('*prop_add') && exists('*prop_type_add') && has('patch-9.0.0185')
    try
      if empty(prop_type_get('VimToolsAICompletion'))
        call prop_type_add('VimToolsAICompletion', {'highlight': 'VimToolsAICompletion'})
      endif
      let s:ghost = a:text
      let l:lines = split(a:text, "\n", 1)
      if !empty(l:lines) && empty(l:lines[-1])
        call remove(l:lines, -1)
      endif
      if empty(l:lines)
        return
      endif
      call prop_add(line('.'), col('.'), {'type': 'VimToolsAICompletion', 'text': l:lines[0]})
      for l:line in l:lines[1:]
        call prop_add(line('.'), 0, {'type': 'VimToolsAICompletion', 'text_align': 'below', 'text': l:line})
      endfor
      return
    catch
      call s:ClearGhost()
    endtry
  endif
  call complete(s:request.column, [{'word': a:text, 'menu': '[AI: ' . s:provider . ']'}])
endfunction

function! s:FMInstructions(kind) abort
  return index(['complete', 'auto_complete'], a:kind) >= 0
        \ ? 'Complete source code at <<<CURSOR>>>. Return only the missing suffix. Never repeat existing code or copy following lines. No explanation or markdown.'
        \ : 'Return only the requested replacement source code. No explanation or markdown.'
endfunction

function! s:AICommand(prompt, output_path) abort
  if s:provider ==# 'copilot'
    return [s:cli, '-p', a:prompt, '--silent',
          \ '--deny-tool=shell', '--deny-tool=write',
          \ '--deny-tool=create', '--deny-tool=edit', '--deny-tool=apply_patch',
          \ '--deny-tool=web_fetch',
          \ '--deny-tool=task', '--deny-tool=skill']
  elseif s:provider ==# 'codex'
    return [s:cli, 'exec', '--ephemeral', '--sandbox', 'read-only',
          \ '--skip-git-repo-check', '--output-last-message', a:output_path, a:prompt]
  elseif s:provider ==# 'fm'
    return [s:cli, 'respond', '--no-stream', '--instructions',
          \ s:FMInstructions(get(s:request, 'kind', '')), a:prompt]
  endif
  return [s:cli, '--print', '--output-format', 'text', '--permission-mode', 'plan',
        \ '--no-session-persistence', a:prompt]
endfunction

function! s:AIOut(channel, message) abort
  if !empty(a:message)
    let s:request.output .= a:message . "\n"
  endif
endfunction

function! s:AIErr(channel, message) abort
  if !empty(a:message)
    let s:request.error .= a:message . "\n"
  endif
endfunction

function! s:CleanResponse(text) abort
  let l:text = substitute(a:text, "\r", '', 'g')
  let l:text = substitute(l:text, '^\_s*\|\_s*$', '', 'g')
  if l:text =~# '^```'
    let l:text = substitute(l:text, '^```[^\n]*\n', '', '')
    let l:text = substitute(l:text, '\n```\s*$', '', '')
  endif
  return l:text
endfunction

function! s:CleanFMCompletion(text) abort
  let l:text = substitute(a:text, "\r", '', 'g')
  let l:lines = split(l:text, "\n", 1)
  call filter(l:lines, 'v:val !~# ''^\s*```''')
  while !empty(l:lines) && empty(l:lines[-1])
    call remove(l:lines, -1)
  endwhile
  return join(l:lines, "\n")
endfunction

function! s:FMCompletionLooksUseful(text, prefix) abort
  if empty(a:text) || a:text =~# '[+*/=-]\s*$'
    return 0
  endif
  if a:prefix =~# '=\s*$' && a:text =~# '^\s*[$@%]\h\w*\s*='
    return 0
  endif
  if a:prefix =~# '=\s*$' && a:text =~# '^\s*\(my\|our\|use\|package\|sub\)\>'
    return 0
  endif
  if a:prefix =~# '=\s*$' && a:text =~# '^\s*__\u\+__\s*$'
    return 0
  endif
  if a:prefix =~# '=\s*$' && a:text =~# '^\s*\h\w*\s*=>'
    return 0
  endif
  if a:prefix =~# '{\s*$' && a:text !~# '}'
    return 0
  endif
  if a:prefix =~# '(\s*$' && a:text !~# ')'
    return 0
  endif
  if line('.') < line('$')
    let l:first = trim(get(split(a:text, "\n"), 0, ''))
    for l:existing in getline(line('.') + 1, min([line('$'), line('.') + 10]))
      if !empty(l:first) && l:first ==# trim(l:existing)
        return 0
      endif
    endfor
  endif
  return 1
endfunction

function! s:FMKnownCompletion(prefix) abort
  if &filetype !=# 'perl' || line('.') < 2
        \ || !empty(strpart(getline('.'), col('.') - 1))
    return ''
  endif
  if a:prefix =~# '^\s*my\s\+\$now\s*=\s*$'
    for l:source_line in getline(1, line('.') - 1)
      if l:source_line =~# '^\s*use\s\+DateTime\s*;'
        return 'DateTime->now();'
      endif
    endfor
  endif
  if a:prefix =~# '^\s*my\s\+\$\%(count\|\h\w*_count\)\s*=\s*$'
    let l:arrays = []
    for l:source_line in getline(max([1, line('.') - 10]), line('.') - 1)
      let l:match = matchlist(l:source_line, '^\s*my\s\+@\(\h\w*\)\>')
      if !empty(l:match) && index(l:arrays, l:match[1]) < 0
        call add(l:arrays, l:match[1])
      endif
    endfor
    if len(l:arrays) == 1
      return 'scalar @' . l:arrays[0] . ';'
    endif
  endif
  return ''
endfunction

function! s:StripRepeatedPrefix(response, prefix) abort
  let l:best = 0
  for l:prefix in [a:prefix, substitute(a:prefix, '^\s*', '', '')]
    let l:maximum = min([strlen(l:prefix), strlen(a:response)])
    if l:maximum < 3
      continue
    endif
    for l:length in reverse(range(3, l:maximum))
      if l:length <= l:best
        break
      endif
      if strpart(l:prefix, strlen(l:prefix) - l:length) ==# strpart(a:response, 0, l:length)
        let l:best = l:length
        break
      endif
    endfor
  endfor
  return strpart(a:response, l:best)
endfunction

function! s:IdentifierCandidates(fragment) abort
  if strlen(a:fragment) < 3
    return []
  endif
  let l:before = line('.') > 1
        \ ? join(getline(max([1, line('.') - 80]), line('.') - 1), "\n") : ''
  let l:before .= ' ' . strpart(getline('.'), 0, col('.') - 1 - strlen(a:fragment))
  let l:candidates = []
  for l:word in split(l:before, '\W\+')
    if strlen(l:word) > strlen(a:fragment) && stridx(l:word, a:fragment) == 0
          \ && index(l:candidates, l:word) < 0
      call add(l:candidates, l:word)
      if len(l:candidates) >= 8
        break
      endif
    endif
  endfor
  return l:candidates
endfunction

function! s:FMIdentifierCompletion(response, prefix, fragment, candidates) abort
  let l:trimmed_prefix = substitute(a:prefix, '^\s*', '', '')
  for l:line in split(a:response, "\n")
    let l:line = substitute(l:line, '^\s*', '', '')
    let l:continuation = s:StripRepeatedPrefix(l:line, a:prefix)
    if empty(l:continuation)
      continue
    endif
    for l:candidate in a:candidates
      let l:suffix = strpart(l:candidate, strlen(a:fragment))
      if stridx(l:continuation, l:suffix) == 0
        return l:continuation
      endif
    endfor
    if empty(a:candidates) && (stridx(l:line, l:trimmed_prefix) == 0
          \ || stridx(l:line, a:fragment) == 0)
      return l:continuation
    endif
  endfor
  return ''
endfunction

function! s:AIExit(job, status) abort
  if s:provider ==# 'codex' && !empty(get(s:request, 'output_path', ''))
    if filereadable(s:request.output_path)
      let s:request.output = join(readfile(s:request.output_path, 'b'), "\n")
    endif
    call delete(s:request.output_path)
  endif
  if get(s:request, 'via_server', 0) && a:status == 0
    try
      let l:reply = json_decode(s:request.output)
      let s:request.output = l:reply.choices[0].message.content
      let s:request.error = ''
    catch
      let s:request.output = ''
      let s:request.error = 'fm serve returned an invalid response.'
    endtry
  endif
  let l:fm_completion = s:provider ==# 'fm'
        \ && index(['complete', 'auto_complete'], get(s:request, 'kind', '')) >= 0
  let l:response = l:fm_completion
        \ ? s:CleanFMCompletion(s:request.output) : s:CleanResponse(s:request.output)
  let l:discarded = 0
  if l:fm_completion
    let l:fragment = get(s:request, 'fragment', '')
    let l:response = strlen(l:fragment) >= 3
          \ ? s:FMIdentifierCompletion(l:response, get(s:request, 'prefix', ''), l:fragment,
          \     get(s:request, 'candidates', []))
          \ : s:StripRepeatedPrefix(l:response, get(s:request, 'prefix', ''))
    if get(s:request, 'filetype', '') ==# 'perl'
          \ && get(s:request, 'prefix', '') =~# '^\s*my\s\+\$\%(count\|\h\w*_count\)\s*=\s*$'
          \ && empty(get(s:request, 'suffix', ''))
          \ && l:response =~# '^scalar\s\+@\h\w*$'
      let l:response .= ';'
    endif
    if get(s:request, 'filetype', '') ==# 'java'
          \ && get(s:request, 'prefix', '') =~# '^\s*System\.out\.$'
          \ && empty(get(s:request, 'suffix', ''))
          \ && l:response =~# '^\%(print\|println\|printf\)(.\+)$'
      let l:response .= ';'
    endif
    if !s:FMCompletionLooksUseful(l:response, get(s:request, 'prefix', ''))
      let l:response = ''
    endif
    let l:discarded = empty(l:response) && a:status == 0
  endif
  if a:status != 0 || empty(l:response)
    if !l:discarded
      let l:message = empty(s:request.error)
            \ ? printf('AI CLI exited with status %d and returned no completion.', a:status)
            \ : substitute(s:request.error, '\n\+$', '', '')
      echohl ErrorMsg
      echom 'AI: ' . l:message
      echohl None
    endif
    let s:job = 0
    if s:auto_rerun
      let s:auto_rerun = 0
      if mode() =~# '^i' && &buftype ==# ''
        let s:auto_timer = timer_start(400, function('s:AutoComplete'))
      endif
    endif
    return
  endif

  if index(['complete', 'auto_complete'], get(s:request, 'kind', '')) >= 0
    let l:request_matches = bufnr('%') == s:request.buffer
          \ && line('.') == s:request.line && col('.') == s:request.column
          \ && b:changedtick == s:request.changedtick
          \ && strpart(getline('.'), 0, col('.') - 1) ==# s:request.prefix
    if l:request_matches && mode() =~# '^i'
      try
        call s:StopAutoTimer()
        call s:ShowSuggestion(l:response)
      catch
        let s:request.pending = l:response
        echom 'AI suggestion is ready; :AIAccept returns to its original location and inserts it.'
      endtry
    elseif get(s:request, 'kind', '') ==# 'auto_complete'
      if bufnr('%') == s:request.buffer && mode() =~# '^i'
        let s:auto_rerun = 1
      endif
    else
      let s:request.pending = l:response
      echom 'AI suggestion is ready; :AIAccept returns to its original location and inserts it.'
    endif
  elseif bufnr('%') == s:request.buffer && getbufvar(s:request.buffer, 'changedtick') == s:request.changedtick
    call setbufline(s:request.buffer, s:request.startline, split(l:response, "\n", 1))
    if s:request.endline > s:request.startline
      call deletebufline(s:request.buffer, s:request.startline + len(split(l:response, "\n", 1)), s:request.endline)
    endif
    echom 'AI response inserted with ' . s:provider . '.'
  else
    let s:request.pending = l:response
    echom 'AI response is ready; the buffer changed, so it was not inserted.'
  endif
  let s:job = 0
  if s:auto_rerun
    let s:auto_rerun = 0
    if mode() =~# '^i' && &buftype ==# ''
      let s:auto_timer = timer_start(400, function('s:AutoComplete'))
    endif
  endif
endfunction

function! s:Start(prompt, kind) abort
  if !executable(s:cli)
    echoerr 'AI CLI not found: ' . s:provider . '. Install and authenticate it, then rerun the Vim setup.'
    return
  endif
  if s:JobRunning()
    echom 'An AI request is already running; duplicate request ignored.'
    return
  endif

  let s:request = {
        \ 'kind': a:kind, 'output': '', 'error': '', 'buffer': bufnr('%'),
        \ 'line': line('.'), 'column': col('.'), 'prefix': strpart(getline('.'), 0, col('.') - 1),
        \ 'suffix': strpart(getline('.'), col('.') - 1), 'filetype': &filetype,
        \ 'workspace': getcwd(),
        \ 'changedtick': b:changedtick,
        \ 'startline': get(s:, 'generate_start', line('.')),
        \ 'endline': get(s:, 'generate_end', line('.'))
        \ }
  if s:provider ==# 'fm' && index(['complete', 'auto_complete'], a:kind) >= 0
    let s:request.fragment = matchstr(s:request.prefix, '\h\w*$')
    let s:request.candidates = s:IdentifierCandidates(s:request.fragment)
  endif
  let l:argv = []
  if s:provider ==# 'codex'
    let s:request.output_path = tempname()
    call writefile([], s:request.output_path)
    let l:argv = s:AICommand(a:prompt, s:request.output_path)
  elseif s:provider ==# 'fm' && s:StartFMServer() && executable('curl')
    let s:request.via_server = 1
    let l:argv = ['curl', '--silent', '--show-error', '--fail', '--noproxy', '*',
          \ '--retry', '20', '--retry-connrefused', '--retry-delay', '1',
          \ '--retry-max-time', '30', '--max-time', '60',
          \ '-H', 'Content-Type: application/json', '--data-binary', '@-',
          \ '--write-out', '\n',
          \ 'http://127.0.0.1:' . s:fm_port . '/v1/chat/completions']
  else
    let l:argv = s:AICommand(a:prompt, '')
  endif
  let l:options = {
        \ 'out_cb': function('s:AIOut'), 'err_cb': function('s:AIErr'),
        \ 'exit_cb': function('s:AIExit'), 'out_mode': 'nl', 'err_mode': 'nl',
        \ 'cwd': getcwd()
        \ }
  if get(s:request, 'via_server', 0)
    let l:options.in_io = 'pipe'
    let l:options.in_mode = 'raw'
  endif
  let s:job = job_start(l:argv, l:options)
  if job_status(s:job) !=# 'run'
    if !empty(get(s:request, 'output_path', ''))
      call delete(s:request.output_path)
    endif
    let s:job = 0
    echoerr 'Could not start ' . s:provider . ' CLI.'
    return
  endif
  if get(s:request, 'via_server', 0)
    let l:payload = {'model': 'system', 'stream': v:false,
          \ 'messages': [
          \   {'role': 'system', 'content': s:FMInstructions(a:kind)},
          \   {'role': 'user', 'content': a:prompt}
          \ ]}
    call ch_sendraw(s:job, json_encode(l:payload))
    call ch_close_in(s:job)
  endif
  echom 'AI completion requested from ' . s:provider . '.'
endfunction

function! s:FMImports() abort
  let l:imports = []
  for l:source_line in getline(1, min([line('$'), 500]))
    if l:source_line !~# '^\s*\(use\|import\)\s\+\S'
          \ || l:source_line =~# '^\s*use\s\+\(strict\|warnings\|utf8\|feature\)\>'
      continue
    endif
    call add(l:imports, strpart(trim(l:source_line), 0, 120))
    if len(l:imports) >= 12
      break
    endif
  endfor
  return l:imports
endfunction

function! s:CompletionContext(...) abort
  let l:current_line = getline('.')
  let l:cursor_offset = col('.') - 1
  let l:context = [
        \ 'Workspace directory: ' . getcwd(),
        \ 'Current file: ' . (empty(expand('%:p')) ? '[unnamed buffer]' : expand('%:p')),
        \ 'Filetype: ' . &filetype,
        \ 'Cursor position: line ' . line('.') . ', byte column ' . col('.'),
        \ (a:0 && a:1 ==# 'assistant'
        \   ? 'Use this project context to answer the user request.'
        \   : 'Return only the text to insert at the cursor. Do not include explanations or markdown fences.'),
        \ ''
        \ ]
  if s:provider ==# 'fm'
    let l:context = ['Language: ' . &filetype]
    let l:imports = s:FMImports()
    if !empty(l:imports)
      call add(l:context, 'Imports: ' . join(l:imports, ' | '))
    endif
    let l:before = line('.') > 1
          \ ? join(getline(max([1, line('.') - 10]), line('.') - 1), "\n") : ''
    let l:after = line('.') < line('$')
          \ ? join(getline(line('.') + 1, min([line('$'), line('.') + 10])), "\n") : ''
    let l:current_line = strpart(l:current_line, max([0, l:cursor_offset - 3000]), min([3000, l:cursor_offset]))
          \ . '<<<CURSOR>>>' . strpart(l:current_line, l:cursor_offset, 1000)
    call extend(l:context, [
          \ 'Previous 10 lines:',
          \ strpart(l:before, max([0, strlen(l:before) - 1600])),
          \ 'Current line:',
          \ l:current_line,
          \ 'Next 10 lines (already present):',
          \ strpart(l:after, 0, 1600)
          \ ])
  else
    let l:current_lines = getline(1, '$')
    let l:current_lines[line('.') - 1] = strpart(l:current_line, 0, l:cursor_offset)
          \ . '<<<CURSOR>>>' . strpart(l:current_line, l:cursor_offset)
    call extend(l:context, [
          \ 'Current buffer snapshot (full in-memory file, including unsaved changes; <<<CURSOR>>> marks the insertion point):',
          \ '```' . &filetype,
          \ join(l:current_lines, "\n"),
          \ '```'
          \ ])
  endif

  let l:other_buffers = []
  let l:workspace = fnamemodify(getcwd(), ':p')
  let l:workspace_prefix = l:workspace =~# '[/\\]$' ? l:workspace : l:workspace . '/'
  let l:context_size = 0
  for l:buffer in getbufinfo()
    if s:provider ==# 'fm'
      break
    endif
    if l:buffer.bufnr == bufnr('%') || !l:buffer.loaded
      continue
    endif
    let l:name = bufname(l:buffer.bufnr)
    if empty(l:name) || getbufvar(l:buffer.bufnr, '&buftype') !=# ''
          \ || getbufvar(l:buffer.bufnr, '&binary')
      continue
    endif
    let l:path = fnamemodify(l:name, ':p')
    if stridx(l:path, l:workspace_prefix) != 0
      continue
    endif
    let l:contents = join(getbufline(l:buffer.bufnr, 1, '$'), "\n")
    if strlen(l:contents) > 8000 || l:context_size + strlen(l:contents) > 16000
      continue
    endif
    call add(l:other_buffers, 'File: ' . l:path . "\n```"
          \ . getbufvar(l:buffer.bufnr, '&filetype') . "\n"
          \ . l:contents . "\n```")
    let l:context_size += strlen(l:contents)
    if len(l:other_buffers) >= 3
      break
    endif
  endfor
  call add(l:context, '')
  if s:provider !=# 'fm'
    call add(l:context, 'Other open project buffers (up to 8 KB each, 16 KB total):')
    call extend(l:context, empty(l:other_buffers) ? ['[No other loaded project buffers]'] : l:other_buffers)
  endif
  return join(l:context, "\n")
endfunction

function! s:StartCompletion(kind) abort
  call s:StopAutoTimer()
  if !has('job') || !has('channel')
    echoerr 'AI completion requires Vim +job and +channel.'
    return
  endif
  if s:JobRunning()
    if a:kind ==# 'auto_complete'
      let s:auto_rerun = 1
    else
      echom 'An AI request is already running; duplicate request ignored.'
    endif
    return
  endif
  let l:prefix = strpart(getline('.'), 0, col('.') - 1)
  let l:fragment = matchstr(l:prefix, '\h\w*$')
  if s:provider ==# 'fm'
    let l:known = s:FMKnownCompletion(l:prefix)
    if !empty(l:known)
      let s:request = {'kind': a:kind, 'buffer': bufnr('%'), 'line': line('.'),
            \ 'column': col('.'), 'prefix': l:prefix, 'pending': l:known}
      if mode() =~# '^i'
        call s:ShowSuggestion(l:known)
      else
        echom 'AI suggestion is ready; use :AIAccept to insert it.'
      endif
      return
    endif
  endif
  let l:instruction = s:provider ==# 'fm'
        \ ? 'Complete the current code. Return only the missing suffix. Use nearby code and imports. Finish the current line first; include more lines only for an opened block.'
        \ : 'Complete the code at the cursor using only the supplied in-memory context. Do not call tools, run commands, or modify files. Keep the completion concise and syntactically consistent.'
  if s:provider ==# 'fm' && strlen(l:fragment) >= 3
    let l:candidates = s:IdentifierCandidates(l:fragment)
    let l:instruction = 'Finish the partial identifier ' . l:fragment
          \ . ' on the current line, then complete its expression.'
    if !empty(l:candidates)
      let l:instruction .= ' Identifiers already present in this buffer that match the fragment: '
            \ . join(l:candidates, ', ') . '. Use one of these names if appropriate.'
    endif
  endif
  let l:prompt = l:instruction . "\n\n" . s:CompletionContext()
  if s:provider ==# 'fm'
    let l:prompt .= "\n\nComplete this target line: " . l:prefix
          \ . '<<<CURSOR>>>'
          \ . "\nOutput only its missing suffix."
  endif
  call s:Start(l:prompt, a:kind)
endfunction

function! VimToolsAIComplete() abort
  call s:StartCompletion('complete')
endfunction

function! VimToolsAIGenerate(startline, endline, instruction) abort
  if !has('job') || !has('channel')
    echoerr 'AI generation requires Vim +job and +channel.'
    return
  endif
  let s:generate_start = a:startline
  let s:generate_end = a:endline
  let l:source = join(getline(a:startline, a:endline), "\n")
  let l:instruction = empty(a:instruction) ? input('AI instruction: ') : a:instruction
  if empty(l:instruction)
    return
  endif
  let l:prompt = 'Apply this instruction to the supplied source and return only the complete replacement source text. Do not use markdown fences or explanations. Filetype: ' . &filetype . "\nInstruction: " . l:instruction . "\nSource:\n" . l:source
  call s:Start(l:prompt, 'generate')
endfunction

function! VimToolsAIStart(instruction) abort
  let l:instruction = empty(a:instruction) && s:provider !=# 'fm'
        \ ? input('Ask ' . s:provider . ': ') : a:instruction
  if empty(l:instruction) && s:provider !=# 'fm'
    return
  endif
  if !executable(s:cli)
    echoerr 'AI CLI not found: ' . s:provider . '. Install and authenticate it, then rerun the Vim setup.'
    return
  endif
  let l:context = 'Opened from Vim. Workspace directory: ' . getcwd()
        \ . '. User request: ' . l:instruction . "\n\n" . s:CompletionContext('assistant')
  if s:provider !=# 'fm'
    let l:context .= "\n\nInspect relevant workspace files and project instructions with read-only tools before responding. Do not run commands or modify files."
  endif
  if s:provider ==# 'copilot'
    let l:argv = [s:cli, '--interactive', l:context]
  elseif s:provider ==# 'codex'
    let l:argv = [s:cli, l:context]
  elseif s:provider ==# 'fm'
    let l:argv = empty(l:instruction)
          \ ? [s:cli, 'chat', '--instructions', l:context]
          \ : [s:cli, 'respond', '--no-stream', '--instructions',
          \    'Answer the user request using the supplied in-memory Vim context.', l:context]
  else
    let l:argv = [s:cli, l:context]
  endif
  try
    call term_start(l:argv, {'cwd': getcwd(), 'term_name': 'AI: ' . s:provider})
  catch
    echoerr 'Could not open AI assistant terminal: ' . v:exception
  endtry
endfunction

function! VimToolsAIAccept() abort
  let l:text = get(s:request, 'pending', '')
  if empty(l:text)
    echoerr 'No pending AI response.'
    return
  endif
  let l:buffer = get(s:request, 'buffer', -1)
  let l:target_line = get(s:request, 'line', 0)
  let l:column = get(s:request, 'column', 0)
  if !bufexists(l:buffer)
    echom 'AI suggestion target no longer exists; response was not inserted.'
    return
  endif
  let l:target = getbufline(l:buffer, l:target_line)
  if empty(l:target) || l:column < 1
    echom 'AI suggestion target no longer exists; response was not inserted.'
    return
  endif
  let l:line = l:target[0]
  let l:prefix = get(s:request, 'prefix', '')
  if strpart(l:line, 0, l:column - 1) !=# l:prefix
    echom 'AI suggestion target changed; response was not inserted.'
    return
  endif
  if bufnr('%') != l:buffer
    execute 'buffer! ' . l:buffer
  endif
  call cursor(l:target_line, l:column)
  let l:suffix = strpart(l:line, l:column - 1)
  let l:parts = split(l:text, "\n", 1)
  if len(l:parts) == 1
    call setline(l:target_line, l:prefix . l:parts[0] . l:suffix)
  else
    let l:parts[0] = l:prefix . l:parts[0]
    let l:parts[-1] .= l:suffix
    call setline(l:target_line, l:parts[0])
    call append(l:target_line, l:parts[1:])
  endif
  call cursor(l:target_line + len(l:parts) - 1, strlen(l:parts[-1]) - strlen(l:suffix) + 1)
  let s:request.pending = ''
endfunction

function! VimToolsAIAcceptGhost() abort
  if !empty(s:ghost)
    let l:text = s:ghost
    call s:ClearGhost()
    return l:text
  endif
  return "\<C-y>"
endfunction

function! VimToolsAIQueuedSuggestion() abort
  return remove(s:, 'accepted_ghost')
endfunction

function! VimToolsAIAcceptTab() abort
  if !empty(s:ghost)
    let l:text = s:ghost
    call s:ClearGhost()
    let s:accepted_ghost = l:text
    let l:register = l:text =~# "\n" ? "\<C-R>\<C-O>=" : "\<C-R>\<C-R>="
    return l:register . 'VimToolsAIQueuedSuggestion()' . "\<CR>"
  endif
  if pumvisible()
    return "\<C-y>"
  endif
  if type(s:tab_fallback) == v:t_func
    try
      return call(s:tab_fallback, [])
    catch
      return "\<Tab>"
    endtry
  endif
  return s:tab_fallback
endfunction

function! s:MapTab() abort
  let l:tab_map = maparg('<Tab>', 'i', 0, 1)
  if has_key(l:tab_map, 'rhs') && l:tab_map.rhs =~# 'VimToolsAIAcceptTab'
    return
  endif
  if has_key(l:tab_map, 'rhs')
    if get(l:tab_map, 'expr', 0)
      let s:tab_fallback = '{ -> ' . l:tab_map.rhs . ' }'
      let s:tab_fallback = substitute(s:tab_fallback, '<SID>', '<SNR>' . get(l:tab_map, 'sid') . '_', 'g')
      let s:tab_fallback = eval(s:tab_fallback)
    else
      let s:tab_fallback = substitute(json_encode(l:tab_map.rhs), '<', '\\<', 'g')
      let s:tab_fallback = eval(s:tab_fallback)
    endif
  else
    let s:tab_fallback = "\<Tab>"
  endif
  inoremap <script><silent><expr> <Tab> VimToolsAIAcceptTab()
endfunction

command! AIComplete call VimToolsAIComplete()
command! -range -nargs=* AIGenerate call VimToolsAIGenerate(<line1>, <line2>, <q-args>)
command! -nargs=* AIAssistant call VimToolsAIStart(<q-args>)
command! AIAccept call VimToolsAIAccept()
command! AIDismiss call s:ClearGhost()
inoremap <silent> <C-x><C-a> <C-o>:call VimToolsAIComplete()<CR>
inoremap <silent><expr> <C-y> VimToolsAIAcceptGhost()
call s:MapTab()

augroup vim_tools_ai_completion
  autocmd!
  autocmd TextChangedI,CursorMovedI * call <SID>ClearGhost() | call <SID>ScheduleCompletion()
  autocmd InsertLeave,BufLeave * call <SID>StopAutoTimer() | call <SID>ClearGhost()
  " Providers such as Codeium remap Tab from their VimEnter handler.
  autocmd VimEnter * call <SID>MapTab()
  autocmd VimEnter * call <SID>StartFMServer()
  autocmd VimLeavePre * call <SID>StopFMServer()
augroup END
