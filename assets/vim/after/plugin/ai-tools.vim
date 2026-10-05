if exists('g:loaded_vim_tools_ai_tools')
  finish
endif
let g:loaded_vim_tools_ai_tools = 1

let s:provider = get(g:, 'vim_tools_ai_provider', 'copilot')
let s:cli = exepath(s:provider)
if empty(s:cli)
  let s:cli = s:provider
endif
let s:request = {}
let s:job = 0
let s:ghost = ''
let s:auto_timer = -1
let s:auto_rerun = 0
let s:accepted_ghost = ''
let s:tab_fallback = get(s:, 'tab_fallback', "\<Tab>")
highlight default link VimToolsAICompletion Comment

function! s:JobRunning() abort
  return type(s:job) == v:t_job && job_status(s:job) ==# 'run'
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
  if !exists('*timer_start') || &buftype !=# '' || empty(&filetype)
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

function! s:AIExit(job, status) abort
  if s:provider ==# 'codex' && !empty(get(s:request, 'output_path', ''))
    if filereadable(s:request.output_path)
      let s:request.output = join(readfile(s:request.output_path, 'b'), "\n")
    endif
    call delete(s:request.output_path)
  endif
  let l:response = s:CleanResponse(s:request.output)
  if a:status != 0 || empty(l:response)
    let l:message = empty(s:request.error)
          \ ? printf('AI CLI exited with status %d and returned no completion.', a:status)
          \ : substitute(s:request.error, '\n\+$', '', '')
    echohl ErrorMsg
    echom 'AI: ' . l:message
    echohl None
    let s:job = 0
    if s:auto_rerun
      let s:auto_rerun = 0
      if mode() =~# '^i' && &buftype ==# '' && !empty(&filetype)
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
    if mode() =~# '^i' && &buftype ==# '' && !empty(&filetype)
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
        \ 'workspace': getcwd(),
        \ 'changedtick': b:changedtick,
        \ 'startline': get(s:, 'generate_start', line('.')),
        \ 'endline': get(s:, 'generate_end', line('.'))
        \ }
  let l:argv = []
  if s:provider ==# 'codex'
    let s:request.output_path = tempname()
    call writefile([], s:request.output_path)
    let l:argv = s:AICommand(a:prompt, s:request.output_path)
  else
    let l:argv = s:AICommand(a:prompt, '')
  endif
  let l:options = {
        \ 'out_cb': function('s:AIOut'), 'err_cb': function('s:AIErr'),
        \ 'exit_cb': function('s:AIExit'), 'out_mode': 'nl', 'err_mode': 'nl',
        \ 'cwd': getcwd()
        \ }
  let s:job = job_start(l:argv, l:options)
  if job_status(s:job) !=# 'run'
    if !empty(get(s:request, 'output_path', ''))
      call delete(s:request.output_path)
    endif
    let s:job = 0
    echoerr 'Could not start ' . s:provider . ' CLI.'
    return
  endif
  echom 'AI completion requested from ' . s:provider . '.'
endfunction

function! s:CompletionContext() abort
  let l:current_lines = getline(1, '$')
  let l:current_line = getline('.')
  let l:cursor_offset = col('.') - 1
  let l:current_lines[line('.') - 1] = strpart(l:current_line, 0, l:cursor_offset)
        \ . '<<<CURSOR>>>' . strpart(l:current_line, l:cursor_offset)
  let l:context = [
        \ 'Workspace directory: ' . getcwd(),
        \ 'Current file: ' . (empty(expand('%:p')) ? '[unnamed buffer]' : expand('%:p')),
        \ 'Filetype: ' . &filetype,
        \ 'Cursor position: line ' . line('.') . ', byte column ' . col('.'),
        \ 'Return only the text to insert at the cursor. Do not include explanations or markdown fences.',
        \ '',
        \ 'Current buffer snapshot (full in-memory file, including unsaved changes; <<<CURSOR>>> marks the insertion point):',
        \ '```' . &filetype,
        \ join(l:current_lines, "\n"),
        \ '```'
        \ ]

  let l:other_buffers = []
  let l:workspace = fnamemodify(getcwd(), ':p')
  let l:workspace_prefix = l:workspace =~# '[/\\]$' ? l:workspace : l:workspace . '/'
  let l:context_size = 0
  for l:buffer in getbufinfo()
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
  call add(l:context, 'Other open project buffers (up to 8 KB each, 16 KB total):')
  call extend(l:context, empty(l:other_buffers) ? ['[No other loaded project buffers]'] : l:other_buffers)
  return join(l:context, "\n")
endfunction

function! s:StartCompletion(kind) abort
  call s:StopAutoTimer()
  if !has('job') || !has('channel')
    echoerr 'AI completion requires Vim +job and +channel.'
    return
  endif
  let l:prompt = 'Complete the code at the cursor using only the supplied in-memory context. Do not call tools, run commands, or modify files. Keep the completion concise and syntactically consistent.'
        \ . "\n\n" . s:CompletionContext()
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
  let l:instruction = empty(a:instruction) ? input('Ask ' . s:provider . ': ') : a:instruction
  if empty(l:instruction)
    return
  endif
  if !executable(s:cli)
    echoerr 'AI CLI not found: ' . s:provider . '. Install and authenticate it, then rerun the Vim setup.'
    return
  endif
  let l:context = 'Opened from Vim. Workspace directory: ' . getcwd()
        \ . '. User request: ' . l:instruction . "\n\n" . s:CompletionContext()
        \ . "\n\nInspect relevant workspace files and project instructions with read-only tools before responding. Do not run commands or modify files."
  if s:provider ==# 'copilot'
    let l:argv = [s:cli, '--interactive', l:context]
  elseif s:provider ==# 'codex'
    let l:argv = [s:cli, l:context]
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
augroup END
