param(
  [switch]$InstallShortcutOnly,
  [switch]$SmokeTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:UiScriptPath = $MyInvocation.MyCommand.Path
$script:ToolRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:BackendPath = Join-Path $script:ToolRoot 'sync_backend.py'
$script:ShortcutName = 'Codex 对话同步工具.lnk'
$script:IconLocation = 'C:\Windows\System32\imageres.dll,15'
$script:BackupMap = @{}
$script:CandidateMap = @{}
$script:LatestState = $null
$script:LatestCandidates = $null
$script:CandidateListLimit = 1000

function Invoke-Backend {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments
  )

  if (-not (Test-Path -LiteralPath $script:BackendPath)) {
    throw "缺少后端脚本: $script:BackendPath"
  }

  $output = & py -3 $script:BackendPath @Arguments 2>&1
  $exitCode = $LASTEXITCODE
  $text = (($output | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
  if (-not $text) {
    throw '后端没有返回任何内容。'
  }

  try {
    $json = $text | ConvertFrom-Json
  } catch {
    throw "后端 JSON 解析失败。`r`n原始错误: $($_.Exception.Message)`r`n返回内容:`r`n$text"
  }

  if ($exitCode -ne 0 -or -not $json.ok) {
    if ($json.error) {
      throw [string]$json.error
    }
    throw "后端执行失败。`r`n$text"
  }

  return $json
}

function New-DesktopShortcut {
  $desktopPath = [Environment]::GetFolderPath('Desktop')
  $shortcutPath = Join-Path $desktopPath $script:ShortcutName
  $targetPath = Join-Path $PSHOME 'powershell.exe'
  $arguments = "-NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden -File `"$script:UiScriptPath`""

  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($shortcutPath)
  $shortcut.TargetPath = $targetPath
  $shortcut.Arguments = $arguments
  $shortcut.WorkingDirectory = $script:ToolRoot
  $shortcut.IconLocation = $script:IconLocation
  $shortcut.Description = 'Codex history sync UI'
  $shortcut.Save()

  return $shortcutPath
}

if ($InstallShortcutOnly) {
  $createdShortcut = New-DesktopShortcut
  Write-Output "桌面快捷方式已创建: $createdShortcut"
  exit 0
}

function Append-Log {
  param([string]$Message)

  $timestamp = Get-Date -Format 'HH:mm:ss'
  $logBox.AppendText("[$timestamp] $Message`r`n")
  $logBox.SelectionStart = $logBox.TextLength
  $logBox.ScrollToCaret()
}

function Format-Counts {
  param($Counts)

  if (-not $Counts -or $Counts.Count -eq 0) {
    return '无'
  }

  return (($Counts | ForEach-Object { "$($_.provider)=$($_.count)" }) -join ', ')
}

function Format-ModelCounts {
  param($Counts)

  if (-not $Counts -or $Counts.Count -eq 0) {
    return '无'
  }

  return (($Counts | ForEach-Object { "$($_.model)=$($_.count)" }) -join ', ')
}

function Format-ThreadTime {
  param($Row)

  $milliseconds = $null
  if ($Row.updated_at_ms) {
    $milliseconds = [int64]$Row.updated_at_ms
  } elseif ($Row.updated_at) {
    $milliseconds = [int64]$Row.updated_at * 1000
  } elseif ($Row.created_at_ms) {
    $milliseconds = [int64]$Row.created_at_ms
  } elseif ($Row.created_at) {
    $milliseconds = [int64]$Row.created_at * 1000
  }

  if ($null -eq $milliseconds) {
    return '未知时间'
  }

  return [DateTimeOffset]::FromUnixTimeMilliseconds($milliseconds).ToLocalTime().ToString('yyyy-MM-dd HH:mm')
}

function Shorten-Text {
  param(
    [AllowNull()]
    [string]$Text,
    [int]$MaxLength = 46
  )

  if (-not $Text) {
    return '无标题'
  }

  $normalized = ($Text -replace '\s+', ' ').Trim()
  if ($normalized.Length -le $MaxLength) {
    return $normalized
  }

  return $normalized.Substring(0, $MaxLength - 1) + '…'
}

function Refresh-Candidates {
  $candidates = Invoke-Backend @('--json', 'list-candidates', '--limit', ([string]$script:CandidateListLimit))
  $script:LatestCandidates = $candidates
  $candidateList.Items.Clear()
  $script:CandidateMap = @{}

  $defaultIds = @{}
  foreach ($id in @($candidates.default_selected_thread_ids)) {
    $defaultIds[[string]$id] = $true
  }

  foreach ($row in @($candidates.candidates)) {
    $timeText = Format-ThreadTime $row
    $modelText = if ($row.model) { [string]$row.model } else { '(empty)' }
    $titleText = Shorten-Text $row.title
    $cwdText = Shorten-Text $row.cwd 28
    $shortId = ([string]$row.id).Substring(0, [Math]::Min(8, ([string]$row.id).Length))
    $label = "$timeText  [$modelText]  $titleText  @$cwdText  #$shortId"
    $script:CandidateMap[$label] = [string]$row.id
    $index = $candidateList.Items.Add($label)
    if ($defaultIds.ContainsKey([string]$row.id)) {
      $candidateList.SetItemChecked($index, $true)
    }
  }

  $candidateSummaryLabel.Text = "可找回会话: $($candidates.total_candidates)    默认选中最新: $($candidates.default_selected_count)    当前列表: $($candidateList.Items.Count)/最多$($candidates.limit)    排序: 最近在上"
}

function Select-DefaultCandidates {
  if (-not $script:LatestCandidates) {
    return
  }

  $defaultIds = @{}
  foreach ($id in @($script:LatestCandidates.default_selected_thread_ids)) {
    $defaultIds[[string]$id] = $true
  }

  for ($index = 0; $index -lt $candidateList.Items.Count; $index++) {
    $label = [string]$candidateList.Items[$index]
    $threadId = $script:CandidateMap[$label]
    $candidateList.SetItemChecked($index, $defaultIds.ContainsKey($threadId))
  }
}

function Set-AllCandidatesChecked {
  param([bool]$Checked)

  for ($index = 0; $index -lt $candidateList.Items.Count; $index++) {
    $candidateList.SetItemChecked($index, $Checked)
  }
}

function Get-SelectedCandidateIds {
  $ids = New-Object System.Collections.Generic.List[string]
  foreach ($item in $candidateList.CheckedItems) {
    $threadId = $script:CandidateMap[[string]$item]
    if ($threadId) {
      [void]$ids.Add([string]$threadId)
    }
  }
  return $ids.ToArray()
}

function Refresh-State {
  $status = Invoke-Backend @('--json', 'status')
  $script:LatestState = $status

  $providerLabel.Text = "当前 provider: $($status.current_provider)    需同步 provider 线程: $($status.provider_movable_threads)"
  $modelLabel.Text = if ($status.current_model) { "当前模型: $($status.current_model)    需同步模型线程: $($status.model_movable_threads)" } else { '当前模型: 未读取到' }
  $summaryLabel.Text = "线程总数: $($status.total_threads)    可同步线程: $($status.movable_threads)    Rollout文件: $($status.rollout_total)    DB/Rollout不一致: $($status.rollout_db_mismatch_threads)"
  $pathLabel.Text = "数据库: $($status.db_path)"

  $providersView.Items.Clear()
  foreach ($row in $status.provider_counts) {
    $isCurrent = if ($row.provider -eq $status.current_provider) { '是' } else { '' }
    $item = New-Object System.Windows.Forms.ListViewItem([string]$row.provider)
    [void]$item.SubItems.Add([string]$row.count)
    [void]$item.SubItems.Add($isCurrent)
    [void]$providersView.Items.Add($item)
  }

  $backupList.Items.Clear()
  $script:BackupMap = @{}
  foreach ($backup in $status.backups) {
    $label = "$($backup.modified_at)    $($backup.name)"
    $script:BackupMap[$label] = $backup.path
    [void]$backupList.Items.Add($label)
  }

  Refresh-Candidates
  Append-Log "状态已刷新。当前 provider=$($status.current_provider)，当前模型=$($status.current_model)，可同步线程=$($status.movable_threads)，DB/Rollout不一致=$($status.rollout_db_mismatch_threads)。"
}

function Confirm-Action {
  param(
    [string]$Message,
    [string]$Title = '确认操作'
  )

  $choice = [System.Windows.Forms.MessageBox]::Show(
    $Message,
    $Title,
    [System.Windows.Forms.MessageBoxButtons]::OKCancel,
    [System.Windows.Forms.MessageBoxIcon]::Question
  )

  return $choice -eq [System.Windows.Forms.DialogResult]::OK
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Codex 历史同步工具'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(980, 760)
$form.MinimumSize = New-Object System.Drawing.Size(980, 760)
$form.BackColor = [System.Drawing.Color]::FromArgb(247, 248, 250)
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$headerLabel = New-Object System.Windows.Forms.Label
$headerLabel.Text = 'Codex 历史同步工具'
$headerLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 16, [System.Drawing.FontStyle]::Bold)
$headerLabel.AutoSize = $true
$headerLabel.Location = New-Object System.Drawing.Point(20, 18)
$form.Controls.Add($headerLabel)

$warningLabel = New-Object System.Windows.Forms.Label
$warningLabel.Text = '请先关闭 Codex Desktop 再做同步或恢复；否则 Codex 可能同时写库，导致同步不完整或被覆盖。'
$warningLabel.ForeColor = [System.Drawing.Color]::FromArgb(163, 64, 31)
$warningLabel.AutoSize = $true
$warningLabel.Location = New-Object System.Drawing.Point(22, 52)
$form.Controls.Add($warningLabel)

$providerLabel = New-Object System.Windows.Forms.Label
$providerLabel.Text = '当前 provider:'
$providerLabel.AutoSize = $true
$providerLabel.Location = New-Object System.Drawing.Point(22, 88)
$form.Controls.Add($providerLabel)

$modelLabel = New-Object System.Windows.Forms.Label
$modelLabel.Text = '当前模型:'
$modelLabel.AutoSize = $true
$modelLabel.Location = New-Object System.Drawing.Point(22, 112)
$form.Controls.Add($modelLabel)

$summaryLabel = New-Object System.Windows.Forms.Label
$summaryLabel.Text = '线程总数:'
$summaryLabel.AutoSize = $true
$summaryLabel.Location = New-Object System.Drawing.Point(22, 136)
$form.Controls.Add($summaryLabel)

$pathLabel = New-Object System.Windows.Forms.Label
$pathLabel.Text = '数据库:'
$pathLabel.AutoSize = $true
$pathLabel.Location = New-Object System.Drawing.Point(22, 160)
$pathLabel.MaximumSize = New-Object System.Drawing.Size(900, 0)
$form.Controls.Add($pathLabel)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = '刷新状态'
$refreshButton.Size = New-Object System.Drawing.Size(110, 34)
$refreshButton.Location = New-Object System.Drawing.Point(22, 200)
$form.Controls.Add($refreshButton)

$syncButton = New-Object System.Windows.Forms.Button
$syncButton.Text = '同步选中会话'
$syncButton.Size = New-Object System.Drawing.Size(150, 34)
$syncButton.Location = New-Object System.Drawing.Point(142, 200)
$syncButton.BackColor = [System.Drawing.Color]::FromArgb(32, 91, 177)
$syncButton.ForeColor = [System.Drawing.Color]::White
$syncButton.FlatStyle = 'Flat'
$form.Controls.Add($syncButton)

$backupButton = New-Object System.Windows.Forms.Button
$backupButton.Text = '手动备份'
$backupButton.Size = New-Object System.Drawing.Size(110, 34)
$backupButton.Location = New-Object System.Drawing.Point(312, 200)
$form.Controls.Add($backupButton)

$openBackupsButton = New-Object System.Windows.Forms.Button
$openBackupsButton.Text = '打开备份目录'
$openBackupsButton.Size = New-Object System.Drawing.Size(120, 34)
$openBackupsButton.Location = New-Object System.Drawing.Point(442, 200)
$form.Controls.Add($openBackupsButton)

$shortcutButton = New-Object System.Windows.Forms.Button
$shortcutButton.Text = '重建桌面图标'
$shortcutButton.Size = New-Object System.Drawing.Size(120, 34)
$shortcutButton.Location = New-Object System.Drawing.Point(578, 200)
$form.Controls.Add($shortcutButton)

$providersBox = New-Object System.Windows.Forms.GroupBox
$providersBox.Text = 'Provider 统计'
$providersBox.Location = New-Object System.Drawing.Point(22, 252)
$providersBox.Size = New-Object System.Drawing.Size(300, 145)
$form.Controls.Add($providersBox)

$providersView = New-Object System.Windows.Forms.ListView
$providersView.View = 'Details'
$providersView.FullRowSelect = $true
$providersView.GridLines = $true
$providersView.Location = New-Object System.Drawing.Point(12, 26)
$providersView.Size = New-Object System.Drawing.Size(276, 107)
[void]$providersView.Columns.Add('Provider', 140)
[void]$providersView.Columns.Add('线程数', 70)
[void]$providersView.Columns.Add('当前', 50)
$providersBox.Controls.Add($providersView)

$backupsBox = New-Object System.Windows.Forms.GroupBox
$backupsBox.Text = '备份列表'
$backupsBox.Location = New-Object System.Drawing.Point(342, 252)
$backupsBox.Size = New-Object System.Drawing.Size(590, 145)
$form.Controls.Add($backupsBox)

$backupList = New-Object System.Windows.Forms.ListBox
$backupList.Location = New-Object System.Drawing.Point(12, 24)
$backupList.Size = New-Object System.Drawing.Size(566, 72)
$backupsBox.Controls.Add($backupList)

$restoreButton = New-Object System.Windows.Forms.Button
$restoreButton.Text = '恢复选中备份'
$restoreButton.Size = New-Object System.Drawing.Size(120, 32)
$restoreButton.Location = New-Object System.Drawing.Point(12, 104)
$backupsBox.Controls.Add($restoreButton)

$restoreLatestButton = New-Object System.Windows.Forms.Button
$restoreLatestButton.Text = '恢复最新备份'
$restoreLatestButton.Size = New-Object System.Drawing.Size(120, 32)
$restoreLatestButton.Location = New-Object System.Drawing.Point(146, 104)
$backupsBox.Controls.Add($restoreLatestButton)

$candidateBox = New-Object System.Windows.Forms.GroupBox
$candidateBox.Text = '可找回会话'
$candidateBox.Location = New-Object System.Drawing.Point(22, 410)
$candidateBox.Size = New-Object System.Drawing.Size(910, 170)
$form.Controls.Add($candidateBox)

$candidateSummaryLabel = New-Object System.Windows.Forms.Label
$candidateSummaryLabel.Text = '可找回会话:'
$candidateSummaryLabel.AutoSize = $true
$candidateSummaryLabel.Location = New-Object System.Drawing.Point(12, 24)
$candidateBox.Controls.Add($candidateSummaryLabel)

$candidateList = New-Object System.Windows.Forms.CheckedListBox
$candidateList.CheckOnClick = $true
$candidateList.HorizontalScrollbar = $true
$candidateList.Location = New-Object System.Drawing.Point(12, 48)
$candidateList.Size = New-Object System.Drawing.Size(886, 76)
$candidateBox.Controls.Add($candidateList)

$selectDefaultButton = New-Object System.Windows.Forms.Button
$selectDefaultButton.Text = '默认最新20'
$selectDefaultButton.Size = New-Object System.Drawing.Size(100, 30)
$selectDefaultButton.Location = New-Object System.Drawing.Point(12, 132)
$candidateBox.Controls.Add($selectDefaultButton)

$selectAllButton = New-Object System.Windows.Forms.Button
$selectAllButton.Text = '全选最多1000'
$selectAllButton.Size = New-Object System.Drawing.Size(110, 30)
$selectAllButton.Location = New-Object System.Drawing.Point(124, 132)
$candidateBox.Controls.Add($selectAllButton)

$clearSelectionButton = New-Object System.Windows.Forms.Button
$clearSelectionButton.Text = '清空选择'
$clearSelectionButton.Size = New-Object System.Drawing.Size(90, 30)
$clearSelectionButton.Location = New-Object System.Drawing.Point(246, 132)
$candidateBox.Controls.Add($clearSelectionButton)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$logBox.Location = New-Object System.Drawing.Point(22, 595)
$logBox.Size = New-Object System.Drawing.Size(910, 110)
$logBox.BackColor = [System.Drawing.Color]::White
$form.Controls.Add($logBox)

$refreshButton.Add_Click({
  try {
    Refresh-State
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '刷新失败', 'OK', 'Error') | Out-Null
    Append-Log "刷新失败: $($_.Exception.Message)"
  }
})

$selectDefaultButton.Add_Click({
  Select-DefaultCandidates
  Append-Log '已恢复默认选择：最新 20 个可找回会话。'
})

$selectAllButton.Add_Click({
  Set-AllCandidatesChecked $true
  Append-Log "已全选当前列表中的 $($candidateList.Items.Count) 个会话（最多 $script:CandidateListLimit 条）。"
})

$clearSelectionButton.Add_Click({
  Set-AllCandidatesChecked $false
  Append-Log '已清空会话选择。'
})

$syncButton.Add_Click({
  try {
    if (-not $script:LatestState) {
      Refresh-State
    }
    $selectedIds = Get-SelectedCandidateIds
    if ($selectedIds.Count -le 0) {
      [System.Windows.Forms.MessageBox]::Show('请先在“可找回会话”里勾选至少一个会话。', '未选择会话', 'OK', 'Information') | Out-Null
      Append-Log '同步跳过：没有选中的可找回会话。'
      return
    }
    $message = "请先关闭 Codex Desktop，再继续同步。`r`n`r`n将会把选中的旧会话挂到当前设置:`r`nprovider: $($script:LatestState.current_provider)`r`nmodel: $($script:LatestState.current_model)`r`n`r`n本次选中会话数: $($selectedIds.Count)`r`n每次都会先自动备份数据库和受影响的 rollout 元数据文件。"
    if (-not (Confirm-Action -Message $message -Title '确认同步')) {
      Append-Log '用户取消了同步。'
      return
    }

    $backendArgs = New-Object System.Collections.Generic.List[string]
    [void]$backendArgs.Add('--json')
    [void]$backendArgs.Add('sync')
    foreach ($threadId in $selectedIds) {
      [void]$backendArgs.Add('--thread-id')
      [void]$backendArgs.Add([string]$threadId)
    }

    $result = Invoke-Backend -Arguments ($backendArgs.ToArray())
    Append-Log "同步完成。已移动 $($result.updated_rows) 条线程。"
    Append-Log "已同步 rollout 元数据文件: $($result.updated_rollout_files)"
    Append-Log "Provider 同步前: $(Format-Counts $result.before_counts)"
    Append-Log "Provider 同步后: $(Format-Counts $result.after_counts)"
    Append-Log "模型同步前: $(Format-ModelCounts $result.before_model_counts)"
    Append-Log "模型同步后: $(Format-ModelCounts $result.after_model_counts)"
    Append-Log "备份快照: $($result.backup_path)"
    Refresh-State
    [System.Windows.Forms.MessageBox]::Show('同步完成。若左侧历史列表没有立刻刷新，重开一次 Codex 即可。', '同步完成', 'OK', 'Information') | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '同步失败', 'OK', 'Error') | Out-Null
    Append-Log "同步失败: $($_.Exception.Message)"
  }
})

$backupButton.Add_Click({
  try {
    $result = Invoke-Backend @('--json', 'backup')
    Append-Log "手动备份快照完成: $($result.backup_path)"
    Refresh-State
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '备份失败', 'OK', 'Error') | Out-Null
    Append-Log "备份失败: $($_.Exception.Message)"
  }
})

$openBackupsButton.Add_Click({
  try {
    if (-not $script:LatestState) {
      Refresh-State
    }
    $folder = $script:LatestState.backup_dir
    if (-not (Test-Path -LiteralPath $folder)) {
      New-Item -ItemType Directory -Force -Path $folder | Out-Null
    }
    Start-Process explorer.exe $folder
    Append-Log "已打开备份目录: $folder"
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '打开目录失败', 'OK', 'Error') | Out-Null
    Append-Log "打开备份目录失败: $($_.Exception.Message)"
  }
})

$shortcutButton.Add_Click({
  try {
    $path = New-DesktopShortcut
    Append-Log "桌面快捷方式已更新: $path"
    [System.Windows.Forms.MessageBox]::Show("桌面快捷方式已更新：`r`n$path", '完成', 'OK', 'Information') | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '创建快捷方式失败', 'OK', 'Error') | Out-Null
    Append-Log "创建快捷方式失败: $($_.Exception.Message)"
  }
})

$restoreButton.Add_Click({
  try {
    if ($backupList.SelectedItem -eq $null) {
      [System.Windows.Forms.MessageBox]::Show('先在右侧选一个备份。', '未选择备份', 'OK', 'Warning') | Out-Null
      return
    }
    $selectedLabel = [string]$backupList.SelectedItem
    $backupPath = $script:BackupMap[$selectedLabel]
    if (-not $backupPath) {
      throw '无法解析选中的备份路径。'
    }

    $message = "请先关闭 Codex Desktop，再继续恢复。`r`n`r`n将会恢复这个备份：`r`n$backupPath`r`n`r`n恢复前会再自动生成一份安全快照。"
    if (-not (Confirm-Action -Message $message -Title '确认恢复')) {
      Append-Log '用户取消了恢复。'
      return
    }

    $result = Invoke-Backend @('--json', 'restore', '--backup', $backupPath)
    Append-Log "恢复完成。来源备份: $($result.restored_from)"
    Append-Log "恢复 rollout 元数据文件: $($result.restored_rollout_files)"
    Append-Log "恢复前安全快照: $($result.safety_backup)"
    Refresh-State
    [System.Windows.Forms.MessageBox]::Show('恢复完成。建议重开一次 Codex 再看历史列表。', '恢复完成', 'OK', 'Information') | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '恢复失败', 'OK', 'Error') | Out-Null
    Append-Log "恢复失败: $($_.Exception.Message)"
  }
})

$restoreLatestButton.Add_Click({
  try {
    if (-not (Confirm-Action -Message '请先关闭 Codex Desktop，再继续恢复。将会恢复最新备份，并在恢复前再做一次安全快照。' -Title '确认恢复最新备份')) {
      Append-Log '用户取消了恢复最新备份。'
      return
    }

    $result = Invoke-Backend @('--json', 'restore')
    Append-Log "已恢复最新备份: $($result.restored_from)"
    Append-Log "恢复 rollout 元数据文件: $($result.restored_rollout_files)"
    Append-Log "恢复前安全快照: $($result.safety_backup)"
    Refresh-State
    [System.Windows.Forms.MessageBox]::Show('恢复完成。建议重开一次 Codex 再看历史列表。', '恢复完成', 'OK', 'Information') | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '恢复失败', 'OK', 'Error') | Out-Null
    Append-Log "恢复失败: $($_.Exception.Message)"
  }
})

try {
  $createdShortcut = New-DesktopShortcut
  Append-Log "桌面快捷方式已准备好: $createdShortcut"
} catch {
  Append-Log "初始化快捷方式失败: $($_.Exception.Message)"
}

try {
  Refresh-State
} catch {
  Append-Log "初始化状态失败: $($_.Exception.Message)"
  [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '启动失败', 'OK', 'Error') | Out-Null
}

if ($SmokeTest) {
  Write-Output 'Smoke test OK'
  exit 0
}

[void]$form.ShowDialog()
