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
$script:CandidateRows = @()
$script:CandidateCheckedIds = @{}
$script:LatestState = $null
$script:LatestCandidates = $null
$script:CandidateListLimit = 1000
$script:ColorPage = [System.Drawing.Color]::FromArgb(244, 247, 248)
$script:ColorSurface = [System.Drawing.Color]::White
$script:ColorText = [System.Drawing.Color]::FromArgb(23, 33, 43)
$script:ColorMuted = [System.Drawing.Color]::FromArgb(102, 112, 133)
$script:ColorBorder = [System.Drawing.Color]::FromArgb(216, 224, 229)
$script:ColorPrimary = [System.Drawing.Color]::FromArgb(15, 118, 110)
$script:ColorPrimaryDark = [System.Drawing.Color]::FromArgb(17, 94, 89)
$script:ColorWarning = [System.Drawing.Color]::FromArgb(180, 83, 9)
$script:ColorDanger = [System.Drawing.Color]::FromArgb(180, 35, 24)
$script:ColorCurrentRow = [System.Drawing.Color]::FromArgb(238, 246, 245)
$script:ColorDisabledText = [System.Drawing.Color]::FromArgb(152, 162, 179)

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
  if ($Row.activity_at_ms) {
    $milliseconds = [int64]$Row.activity_at_ms
  } elseif ($Row.updated_at_ms) {
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

function Normalize-SearchText {
  param([AllowNull()][string]$Text)

  if (-not $Text) {
    return ''
  }

  return (($Text -replace '\s+', ' ').Trim()).ToLowerInvariant()
}

function Test-CandidateMatchesSearch {
  param($Row)

  $query = Normalize-SearchText $candidateSearchBox.Text
  if (-not $query) {
    return $true
  }

  $haystack = Normalize-SearchText "$($Row.status) $($Row.title) $($Row.cwd) $($Row.model) $($Row.model_provider) $($Row.id)"
  return $haystack.Contains($query)
}

function Sync-CandidateChecksFromView {
  if (-not $candidateList) {
    return
  }

  foreach ($item in $candidateList.Items) {
    $threadId = [string]$item.Tag
    if (-not $threadId) {
      continue
    }
    if ($item.Checked) {
      $script:CandidateCheckedIds[$threadId] = $true
    } else {
      $script:CandidateCheckedIds.Remove($threadId)
    }
  }
}

function Render-Candidates {
  param([bool]$SyncFromView = $true)

  if ($SyncFromView) {
    Sync-CandidateChecksFromView
  }
  $candidateList.BeginUpdate()
  try {
    $candidateList.Items.Clear()
    $script:CandidateMap = @{}

    foreach ($row in @($script:CandidateRows)) {
      if (-not (Test-CandidateMatchesSearch $row)) {
        continue
      }

      $threadId = [string]$row.id
      $timeText = Format-ThreadTime $row
      $modelText = if ($row.model) { [string]$row.model } else { '(empty)' }
      $statusText = if ($row.can_sync) { '可同步' } else { '当前' }
      $titleText = Shorten-Text $row.title 56
      $cwdText = Shorten-Text $row.cwd 42
      $sourceText = if ($row.activity_source -eq 'rollout_mtime') { 'rollout' } else { 'db' }
      $shortId = $threadId.Substring(0, [Math]::Min(8, $threadId.Length))

      $item = New-Object System.Windows.Forms.ListViewItem('')
      $item.Tag = $threadId
      $item.Checked = $script:CandidateCheckedIds.ContainsKey($threadId)
      if (-not $row.can_sync) {
        $item.BackColor = $script:ColorCurrentRow
        $item.ForeColor = $script:ColorDisabledText
      }
      [void]$item.SubItems.Add($statusText)
      [void]$item.SubItems.Add($timeText)
      [void]$item.SubItems.Add($modelText)
      [void]$item.SubItems.Add($titleText)
      [void]$item.SubItems.Add($cwdText)
      [void]$item.SubItems.Add($sourceText)
      [void]$item.SubItems.Add($shortId)
      $item.ToolTipText = "$($row.title)`r`n$($row.cwd)`r`n$threadId"

      $script:CandidateMap[$threadId] = $row
      [void]$candidateList.Items.Add($item)
    }
  } finally {
    $candidateList.EndUpdate()
  }

  Update-CandidateSummary
}

function Update-CandidateSummary {
  $selectedCount = $script:CandidateCheckedIds.Count
  $syncSelectedCount = 0
  foreach ($threadId in $script:CandidateCheckedIds.Keys) {
    $row = $script:CandidateMap[$threadId]
    if ($row -and $row.can_sync) {
      $syncSelectedCount++
    }
  }
  $visibleCount = if ($candidateList) { $candidateList.Items.Count } else { 0 }
  $totalCount = if ($script:LatestCandidates) { $script:LatestCandidates.total_candidates } else { 0 }
  $currentCount = if ($script:LatestCandidates) { $script:LatestCandidates.current_count } else { 0 }
  $threadCount = if ($script:LatestCandidates) { $script:LatestCandidates.total_threads } else { $totalCount }
  $limit = if ($script:LatestCandidates) { $script:LatestCandidates.limit } else { $script:CandidateListLimit }
  $candidateSummaryLabel.Text = "全部: $threadCount    可同步: $totalCount    当前: $currentCount    显示: $visibleCount/$limit    勾选: $selectedCount    可同步勾选: $syncSelectedCount"
  if ($candidateCountValueLabel) {
    $candidateCountValueLabel.Text = "$threadCount / $totalCount"
    $candidateCountDetailLabel.Text = "全部 / 可同步，勾选 $selectedCount"
  }
}

function Refresh-Candidates {
  $candidates = Invoke-Backend @('--json', 'list-candidates', '--limit', ([string]$script:CandidateListLimit), '--include-current')
  $script:LatestCandidates = $candidates
  $script:CandidateRows = @($candidates.candidates)
  $script:CandidateCheckedIds = @{}

  Render-Candidates $false
}

function Select-DefaultCandidates {
  if (-not $script:LatestCandidates) {
    return
  }

  $script:CandidateCheckedIds = @{}
  foreach ($id in @($script:LatestCandidates.default_selected_thread_ids)) {
    $script:CandidateCheckedIds[[string]$id] = $true
  }
  Render-Candidates $false
}

function Set-AllCandidatesChecked {
  param([bool]$Checked)

  if (-not $Checked) {
    $script:CandidateCheckedIds = @{}
  }

  foreach ($item in $candidateList.Items) {
    $threadId = [string]$item.Tag
    if ($Checked) {
      if ($threadId) {
        $script:CandidateCheckedIds[$threadId] = $true
        $item.Checked = $true
      }
    } else {
      $script:CandidateCheckedIds.Remove($threadId)
      $item.Checked = $false
    }
  }
  Update-CandidateSummary
}

function Get-SelectedCandidateIds {
  Sync-CandidateChecksFromView
  $ids = New-Object System.Collections.Generic.List[string]
  foreach ($threadId in $script:CandidateCheckedIds.Keys) {
    $row = $script:CandidateMap[$threadId]
    if ($row -and $row.can_sync) {
      [void]$ids.Add([string]$threadId)
    }
  }
  return ,$ids.ToArray()
}

function Get-CheckedCandidateIds {
  Sync-CandidateChecksFromView
  $ids = New-Object System.Collections.Generic.List[string]
  foreach ($threadId in $script:CandidateCheckedIds.Keys) {
    [void]$ids.Add([string]$threadId)
  }
  return ,$ids.ToArray()
}

function Get-SelectedRowIds {
  $ids = New-Object System.Collections.Generic.List[string]
  foreach ($item in $candidateList.SelectedItems) {
    $threadId = [string]$item.Tag
    if ($threadId) {
      [void]$ids.Add($threadId)
    }
  }
  return ,$ids.ToArray()
}

function Refresh-State {
  $status = Invoke-Backend @('--json', 'status')
  $script:LatestState = $status

  $currentProviderDisplay = if ($status.current_provider_display) { [string]$status.current_provider_display } else { [string]$status.current_provider }
  $providerValueLabel.Text = $currentProviderDisplay
  $profileKind = if ($status.target_provider_profile) { [string]$status.target_provider_profile.kind } else { 'legacy' }
  $providerDetailLabel.Text = "需同步 provider: $($status.provider_movable_threads)"
  $modelValueLabel.Text = if ($status.current_model) { [string]$status.current_model } else { '未读取到' }
  $modelDetailLabel.Text = "需同步模型: $($status.model_movable_threads)"
  $candidateCountValueLabel.Text = [string]$status.movable_threads
  $candidateCountDetailLabel.Text = "线程总数: $($status.total_threads)"
  $rolloutValueLabel.Text = "$($status.rollout_total) 文件"
  $rolloutDetailLabel.Text = "DB/Rollout 不一致: $($status.rollout_db_mismatch_threads)"
  $pathLabel.Text = "数据库  $($status.db_path)"

  $providersView.Items.Clear()
  foreach ($row in $status.provider_counts) {
    $isProviderlessCurrent = (-not $status.current_provider) -and ($row.provider -eq '(empty)')
    $isCurrent = if (($row.provider -eq $status.current_provider) -or $isProviderlessCurrent) { '是' } else { '' }
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
  Append-Log "状态已刷新。当前 provider=$currentProviderDisplay，目标形态=$profileKind，当前模型=$($status.current_model)，可同步线程=$($status.movable_threads)，DB/Rollout不一致=$($status.rollout_db_mismatch_threads)。"
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

function New-StatusCard {
  param(
    [string]$Title,
    [int]$X
  )

  $panel = New-Object System.Windows.Forms.Panel
  $panel.Location = New-Object System.Drawing.Point($X, 82)
  $panel.Size = New-Object System.Drawing.Size(260, 76)
  $panel.BackColor = $script:ColorSurface
  $panel.BorderStyle = 'FixedSingle'
  $form.Controls.Add($panel)

  $titleLabel = New-Object System.Windows.Forms.Label
  $titleLabel.Text = $Title
  $titleLabel.AutoSize = $true
  $titleLabel.ForeColor = $script:ColorMuted
  $titleLabel.Location = New-Object System.Drawing.Point(12, 10)
  $panel.Controls.Add($titleLabel)

  $valueLabel = New-Object System.Windows.Forms.Label
  $valueLabel.Text = '-'
  $valueLabel.AutoSize = $false
  $valueLabel.Size = New-Object System.Drawing.Size(232, 24)
  $valueLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12, [System.Drawing.FontStyle]::Bold)
  $valueLabel.ForeColor = $script:ColorText
  $valueLabel.Location = New-Object System.Drawing.Point(12, 30)
  $panel.Controls.Add($valueLabel)

  $detailLabel = New-Object System.Windows.Forms.Label
  $detailLabel.Text = '-'
  $detailLabel.AutoSize = $false
  $detailLabel.Size = New-Object System.Drawing.Size(232, 18)
  $detailLabel.ForeColor = $script:ColorMuted
  $detailLabel.Location = New-Object System.Drawing.Point(12, 54)
  $panel.Controls.Add($detailLabel)

  return @{
    Panel = $panel
    Value = $valueLabel
    Detail = $detailLabel
  }
}

function Apply-ResponsiveLayout {
  $left = 22
  $right = 22
  $gap = 14
  $clientWidth = $form.ClientSize.Width
  $clientHeight = $form.ClientSize.Height
  $contentWidth = [Math]::Max(1016, $clientWidth - $left - $right)
  $rightPanelWidth = 326
  $mainTop = 246
  $logHeight = 118
  $bottom = 22
  $mainHeight = [Math]::Max(360, $clientHeight - $mainTop - $logHeight - $gap - $bottom)
  $rightX = $clientWidth - $right - $rightPanelWidth
  $mainWidth = [Math]::Max(620, $rightX - $gap - $left)

  $cardGap = 14
  $cardTop = 82
  $cardWidth = [Math]::Max(230, [Math]::Floor(($contentWidth - ($cardGap * 3)) / 4))
  $statusCards = @($providerCard, $modelCard, $candidateCountCard, $rolloutCard)
  for ($index = 0; $index -lt $statusCards.Count; $index++) {
    $panel = $statusCards[$index]['Panel']
    $panel.Location = New-Object System.Drawing.Point(($left + (($cardWidth + $cardGap) * $index)), $cardTop)
    $panel.Size = New-Object System.Drawing.Size($cardWidth, 76)
    $statusCards[$index]['Value'].Size = New-Object System.Drawing.Size(($cardWidth - 24), 24)
    $statusCards[$index]['Detail'].Size = New-Object System.Drawing.Size(($cardWidth - 24), 18)
  }

  $pathLabel.MaximumSize = New-Object System.Drawing.Size($contentWidth, 0)
  $candidateSearchBox.Size = New-Object System.Drawing.Size([Math]::Max(260, $rightX - 356 - $gap), 24)
  $clearSearchButton.Location = New-Object System.Drawing.Point(($candidateSearchBox.Right + 10), 195)

  $candidateBox.Location = New-Object System.Drawing.Point($left, $mainTop)
  $candidateBox.Size = New-Object System.Drawing.Size($mainWidth, $mainHeight)
  $candidateList.Size = New-Object System.Drawing.Size([Math]::Max(560, $candidateBox.ClientSize.Width - 24), [Math]::Max(220, $candidateBox.ClientSize.Height - 106))

  $candidateList.Columns[0].Width = 34
  $candidateList.Columns[1].Width = 70
  $candidateList.Columns[2].Width = 135
  $candidateList.Columns[3].Width = 150
  $candidateList.Columns[4].Width = 420
  $candidateList.Columns[5].Width = 460
  $candidateList.Columns[6].Width = 76
  $candidateList.Columns[7].Width = 120

  $backupPanelHeight = 324
  $backupsBox.Location = New-Object System.Drawing.Point($rightX, $mainTop)
  $backupsBox.Size = New-Object System.Drawing.Size($rightPanelWidth, $backupPanelHeight)
  $backupList.Size = New-Object System.Drawing.Size(($rightPanelWidth - 24), 112)

  $providersBox.Location = New-Object System.Drawing.Point($rightX, ($backupsBox.Bottom + $gap))
  $providersBox.Size = New-Object System.Drawing.Size($rightPanelWidth, [Math]::Max(132, $mainHeight - $backupsBox.Height - $gap))
  $providersView.Size = New-Object System.Drawing.Size(($rightPanelWidth - 24), [Math]::Max(92, $providersBox.ClientSize.Height - 38))
  $providersView.Columns[0].Width = 220
  $providersView.Columns[1].Width = 90
  $providersView.Columns[2].Width = 70

  $logTop = $mainTop + $mainHeight + $gap
  $logBox.Location = New-Object System.Drawing.Point($left, $logTop)
  $logBox.Size = New-Object System.Drawing.Size($contentWidth, [Math]::Max(90, $clientHeight - $logTop - $bottom))
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Codex 历史同步工具'
$form.StartPosition = 'CenterScreen'
$form.Size = New-Object System.Drawing.Size(1180, 860)
$form.MinimumSize = New-Object System.Drawing.Size(1060, 760)
$form.MaximizeBox = $true
$form.BackColor = $script:ColorPage
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$headerLabel = New-Object System.Windows.Forms.Label
$headerLabel.Text = 'Codex 历史同步工具'
$headerLabel.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 16, [System.Drawing.FontStyle]::Bold)
$headerLabel.AutoSize = $true
$headerLabel.ForeColor = $script:ColorText
$headerLabel.Location = New-Object System.Drawing.Point(22, 14)
$form.Controls.Add($headerLabel)

$warningLabel = New-Object System.Windows.Forms.Label
$warningLabel.Text = '请先关闭 Codex Desktop 再做同步或恢复；否则 Codex 可能同时写库，导致同步不完整或被覆盖。'
$warningLabel.ForeColor = $script:ColorWarning
$warningLabel.AutoSize = $true
$warningLabel.Location = New-Object System.Drawing.Point(24, 48)
$form.Controls.Add($warningLabel)

$providerCard = New-StatusCard '当前 Provider' 22
$providerValueLabel = $providerCard['Value']
$providerDetailLabel = $providerCard['Detail']

$modelCard = New-StatusCard '当前模型' 296
$modelValueLabel = $modelCard['Value']
$modelDetailLabel = $modelCard['Detail']

$candidateCountCard = New-StatusCard '会话视图' 570
$candidateCountValueLabel = $candidateCountCard['Value']
$candidateCountDetailLabel = $candidateCountCard['Detail']

$rolloutCard = New-StatusCard 'Rollout 状态' 844
$rolloutValueLabel = $rolloutCard['Value']
$rolloutDetailLabel = $rolloutCard['Detail']

$pathLabel = New-Object System.Windows.Forms.Label
$pathLabel.Text = '数据库'
$pathLabel.AutoSize = $true
$pathLabel.ForeColor = $script:ColorMuted
$pathLabel.Location = New-Object System.Drawing.Point(24, 166)
$pathLabel.MaximumSize = New-Object System.Drawing.Size(1080, 0)
$form.Controls.Add($pathLabel)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = '刷新状态'
$refreshButton.Size = New-Object System.Drawing.Size(110, 34)
$refreshButton.Location = New-Object System.Drawing.Point(22, 194)
$refreshButton.BackColor = $script:ColorSurface
$form.Controls.Add($refreshButton)

$syncButton = New-Object System.Windows.Forms.Button
$syncButton.Text = '同步选中会话'
$syncButton.Size = New-Object System.Drawing.Size(150, 34)
$syncButton.Location = New-Object System.Drawing.Point(144, 194)
$syncButton.BackColor = $script:ColorPrimary
$syncButton.ForeColor = [System.Drawing.Color]::White
$syncButton.FlatStyle = 'Flat'
$form.Controls.Add($syncButton)

$searchLabel = New-Object System.Windows.Forms.Label
$searchLabel.Text = '搜索'
$searchLabel.AutoSize = $true
$searchLabel.ForeColor = $script:ColorMuted
$searchLabel.Location = New-Object System.Drawing.Point(316, 202)
$form.Controls.Add($searchLabel)

$candidateSearchBox = New-Object System.Windows.Forms.TextBox
$candidateSearchBox.Location = New-Object System.Drawing.Point(356, 198)
$candidateSearchBox.Size = New-Object System.Drawing.Size(360, 24)
$candidateSearchBox.BackColor = $script:ColorSurface
$candidateSearchBox.ForeColor = $script:ColorText
$form.Controls.Add($candidateSearchBox)

$clearSearchButton = New-Object System.Windows.Forms.Button
$clearSearchButton.Text = '清除'
$clearSearchButton.Size = New-Object System.Drawing.Size(70, 30)
$clearSearchButton.Location = New-Object System.Drawing.Point(728, 195)
$clearSearchButton.BackColor = $script:ColorSurface
$form.Controls.Add($clearSearchButton)

$candidateBox = New-Object System.Windows.Forms.GroupBox
$candidateBox.Text = '会话列表'
$candidateBox.ForeColor = $script:ColorText
$candidateBox.Location = New-Object System.Drawing.Point(22, 246)
$candidateBox.Size = New-Object System.Drawing.Size(770, 430)
$form.Controls.Add($candidateBox)

$candidateSummaryLabel = New-Object System.Windows.Forms.Label
$candidateSummaryLabel.Text = '可找回会话:'
$candidateSummaryLabel.AutoSize = $true
$candidateSummaryLabel.Location = New-Object System.Drawing.Point(12, 24)
$candidateBox.Controls.Add($candidateSummaryLabel)

$selectDefaultButton = New-Object System.Windows.Forms.Button
$selectDefaultButton.Text = '默认最新20'
$selectDefaultButton.Size = New-Object System.Drawing.Size(100, 30)
$selectDefaultButton.Location = New-Object System.Drawing.Point(12, 54)
$selectDefaultButton.BackColor = $script:ColorSurface
$candidateBox.Controls.Add($selectDefaultButton)

$selectAllButton = New-Object System.Windows.Forms.Button
$selectAllButton.Text = '全选当前列表'
$selectAllButton.Size = New-Object System.Drawing.Size(118, 30)
$selectAllButton.Location = New-Object System.Drawing.Point(124, 54)
$selectAllButton.BackColor = $script:ColorSurface
$candidateBox.Controls.Add($selectAllButton)

$clearSelectionButton = New-Object System.Windows.Forms.Button
$clearSelectionButton.Text = '清空选择'
$clearSelectionButton.Size = New-Object System.Drawing.Size(90, 30)
$clearSelectionButton.Location = New-Object System.Drawing.Point(254, 54)
$clearSelectionButton.BackColor = $script:ColorSurface
$candidateBox.Controls.Add($clearSelectionButton)

$trashSelectedRowsButton = New-Object System.Windows.Forms.Button
$trashSelectedRowsButton.Text = '删除选中行'
$trashSelectedRowsButton.Size = New-Object System.Drawing.Size(104, 30)
$trashSelectedRowsButton.Location = New-Object System.Drawing.Point(356, 54)
$trashSelectedRowsButton.ForeColor = $script:ColorDanger
$trashSelectedRowsButton.BackColor = $script:ColorSurface
$candidateBox.Controls.Add($trashSelectedRowsButton)

$candidateList = New-Object System.Windows.Forms.ListView
$candidateList.View = 'Details'
$candidateList.CheckBoxes = $true
$candidateList.FullRowSelect = $true
$candidateList.MultiSelect = $true
$candidateList.GridLines = $true
$candidateList.HideSelection = $false
$candidateList.ShowItemToolTips = $true
$candidateList.Scrollable = $true
$candidateList.BackColor = $script:ColorSurface
$candidateList.ForeColor = $script:ColorText
$candidateList.Location = New-Object System.Drawing.Point(12, 94)
$candidateList.Size = New-Object System.Drawing.Size(746, 320)
[void]$candidateList.Columns.Add('', 34)
[void]$candidateList.Columns.Add('状态', 64)
[void]$candidateList.Columns.Add('时间', 120)
[void]$candidateList.Columns.Add('模型', 120)
[void]$candidateList.Columns.Add('标题', 245)
[void]$candidateList.Columns.Add('项目目录', 160)
[void]$candidateList.Columns.Add('来源', 62)
[void]$candidateList.Columns.Add('ID', 78)
$candidateBox.Controls.Add($candidateList)

$backupsBox = New-Object System.Windows.Forms.GroupBox
$backupsBox.Text = '备份与恢复'
$backupsBox.ForeColor = $script:ColorText
$backupsBox.Location = New-Object System.Drawing.Point(814, 246)
$backupsBox.Size = New-Object System.Drawing.Size(326, 324)
$form.Controls.Add($backupsBox)

$backupList = New-Object System.Windows.Forms.ListBox
$backupList.Location = New-Object System.Drawing.Point(12, 24)
$backupList.Size = New-Object System.Drawing.Size(302, 112)
$backupList.HorizontalScrollbar = $true
$backupList.BackColor = $script:ColorSurface
$backupList.ForeColor = $script:ColorText
$backupsBox.Controls.Add($backupList)

$backupButton = New-Object System.Windows.Forms.Button
$backupButton.Text = '手动备份'
$backupButton.Size = New-Object System.Drawing.Size(94, 32)
$backupButton.Location = New-Object System.Drawing.Point(12, 148)
$backupButton.BackColor = $script:ColorSurface
$backupsBox.Controls.Add($backupButton)

$openBackupsButton = New-Object System.Windows.Forms.Button
$openBackupsButton.Text = '打开目录'
$openBackupsButton.Size = New-Object System.Drawing.Size(94, 32)
$openBackupsButton.Location = New-Object System.Drawing.Point(114, 148)
$openBackupsButton.BackColor = $script:ColorSurface
$backupsBox.Controls.Add($openBackupsButton)

$shortcutButton = New-Object System.Windows.Forms.Button
$shortcutButton.Text = '重建图标'
$shortcutButton.Size = New-Object System.Drawing.Size(94, 32)
$shortcutButton.Location = New-Object System.Drawing.Point(216, 148)
$shortcutButton.BackColor = $script:ColorSurface
$backupsBox.Controls.Add($shortcutButton)

$restoreButton = New-Object System.Windows.Forms.Button
$restoreButton.Text = '恢复选中备份'
$restoreButton.Size = New-Object System.Drawing.Size(144, 34)
$restoreButton.Location = New-Object System.Drawing.Point(12, 194)
$restoreButton.ForeColor = $script:ColorDanger
$restoreButton.BackColor = $script:ColorSurface
$backupsBox.Controls.Add($restoreButton)

$restoreLatestButton = New-Object System.Windows.Forms.Button
$restoreLatestButton.Text = '恢复最新备份'
$restoreLatestButton.Size = New-Object System.Drawing.Size(144, 34)
$restoreLatestButton.Location = New-Object System.Drawing.Point(168, 194)
$restoreLatestButton.ForeColor = $script:ColorDanger
$restoreLatestButton.BackColor = $script:ColorSurface
$backupsBox.Controls.Add($restoreLatestButton)

$restoreLatestTrashButton = New-Object System.Windows.Forms.Button
$restoreLatestTrashButton.Text = '恢复最新删除'
$restoreLatestTrashButton.Size = New-Object System.Drawing.Size(144, 34)
$restoreLatestTrashButton.Location = New-Object System.Drawing.Point(12, 242)
$restoreLatestTrashButton.ForeColor = $script:ColorWarning
$restoreLatestTrashButton.BackColor = $script:ColorSurface
$backupsBox.Controls.Add($restoreLatestTrashButton)

$openTrashButton = New-Object System.Windows.Forms.Button
$openTrashButton.Text = '打开回收站'
$openTrashButton.Size = New-Object System.Drawing.Size(144, 34)
$openTrashButton.Location = New-Object System.Drawing.Point(168, 242)
$openTrashButton.BackColor = $script:ColorSurface
$backupsBox.Controls.Add($openTrashButton)

$providersBox = New-Object System.Windows.Forms.GroupBox
$providersBox.Text = 'Provider 统计'
$providersBox.ForeColor = $script:ColorText
$providersBox.Location = New-Object System.Drawing.Point(814, 584)
$providersBox.Size = New-Object System.Drawing.Size(326, 132)
$form.Controls.Add($providersBox)

$providersView = New-Object System.Windows.Forms.ListView
$providersView.View = 'Details'
$providersView.FullRowSelect = $true
$providersView.GridLines = $true
$providersView.Scrollable = $true
$providersView.BackColor = $script:ColorSurface
$providersView.ForeColor = $script:ColorText
$providersView.Location = New-Object System.Drawing.Point(12, 26)
$providersView.Size = New-Object System.Drawing.Size(302, 128)
[void]$providersView.Columns.Add('Provider', 160)
[void]$providersView.Columns.Add('线程数', 78)
[void]$providersView.Columns.Add('当前', 54)
$providersBox.Controls.Add($providersView)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ScrollBars = 'Vertical'
$logBox.ReadOnly = $true
$logBox.Location = New-Object System.Drawing.Point(22, 694)
$logBox.Size = New-Object System.Drawing.Size(1118, 118)
$logBox.BackColor = $script:ColorSurface
$logBox.ForeColor = $script:ColorText
$form.Controls.Add($logBox)

$candidateSearchBox.Add_TextChanged({
  if ($script:LatestCandidates) {
    Render-Candidates
  }
})

$clearSearchButton.Add_Click({
  $candidateSearchBox.Text = ''
})

$candidateList.Add_ItemChecked({
  Update-CandidateSummary
})

$candidateList.Add_ItemCheck({
  param($Sender, $EventArgs)
  # Checkboxes are shared by sync and delete. Sync filters to can_sync rows;
  # delete can use any checked row.
})

$form.Add_Shown({
  Apply-ResponsiveLayout
})

$form.Add_Resize({
  if ($candidateBox -and $candidateList -and $logBox) {
    Apply-ResponsiveLayout
  }
})

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
  Append-Log "已勾选当前列表中的 $($candidateList.Items.Count) 个会话（同步会自动过滤不可同步会话，删除会使用全部勾选会话）。"
})

$clearSelectionButton.Add_Click({
  Set-AllCandidatesChecked $false
  Append-Log '已清空会话选择。'
})

$trashSelectedRowsButton.Add_Click({
  try {
    if (-not $script:LatestState) {
      Refresh-State
    }
    $checkedIds = Get-CheckedCandidateIds
    $rowIds = Get-SelectedRowIds
    $idSet = @{}
    foreach ($threadId in @($checkedIds)) {
      if ($threadId) { $idSet[[string]$threadId] = $true }
    }
    foreach ($threadId in @($rowIds)) {
      if ($threadId) { $idSet[[string]$threadId] = $true }
    }
    $selectedIds = @($idSet.Keys | ForEach-Object { [string]$_ })
    if ($selectedIds.Count -le 0) {
      [System.Windows.Forms.MessageBox]::Show('请先在会话列表里勾选或选中至少一个会话。', '未选择会话', 'OK', 'Information') | Out-Null
      Append-Log '删除跳过：没有勾选或选中的会话。'
      return
    }

    $message = "请先关闭 Codex Desktop，再继续删除。`r`n`r`n将会把选中的会话移入可恢复回收站，而不是永久删除。`r`n本次选中会话数: $($selectedIds.Count)`r`n`r`n如误删，可使用'恢复最新删除'。"
    if (-not (Confirm-Action -Message $message -Title '确认移入回收站')) {
      Append-Log '用户取消了删除。'
      return
    }

    $backendArgs = New-Object System.Collections.Generic.List[string]
    [void]$backendArgs.Add('--json')
    [void]$backendArgs.Add('trash')
    foreach ($threadId in $selectedIds) {
      [void]$backendArgs.Add('--thread-id')
      [void]$backendArgs.Add([string]$threadId)
    }

    $result = Invoke-Backend -Arguments ($backendArgs.ToArray())
    Append-Log "已移入回收站。删除线程: $($result.deleted_rows)，移动 rollout 文件: $($result.moved_rollout_files)"
    Append-Log "回收站快照: $($result.trash_path)"
    Append-Log "删除前安全备份: $($result.safety_backup)"
    Refresh-State
    [System.Windows.Forms.MessageBox]::Show('已移入回收站。若 Codex 历史列表没有立刻刷新，重开一次 Codex 即可。', '删除完成', 'OK', 'Information') | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '删除失败', 'OK', 'Error') | Out-Null
    Append-Log "删除失败: $($_.Exception.Message)"
  }
})

$syncButton.Add_Click({
  try {
    if (-not $script:LatestState) {
      Refresh-State
    }
    $selectedIds = Get-SelectedCandidateIds
    if ($selectedIds.Count -le 0) {
      [System.Windows.Forms.MessageBox]::Show('请先勾选至少一个“可同步”会话。当前会话可以勾选用于删除，但不会参与同步。', '未选择可同步会话', 'OK', 'Information') | Out-Null
      Append-Log '同步跳过：没有选中的可找回会话。'
      return
    }
    $targetProviderDisplay = if ($script:LatestState.current_provider_display) { [string]$script:LatestState.current_provider_display } else { [string]$script:LatestState.current_provider }
    $targetProfileKind = if ($script:LatestState.target_provider_profile) { [string]$script:LatestState.target_provider_profile.kind } else { 'legacy' }
    $message = "请先关闭 Codex Desktop，再继续同步。`r`n`r`n将会把选中的旧会话挂到当前设置:`r`nprovider: $targetProviderDisplay`r`nprovider 形态: $targetProfileKind`r`nmodel: $($script:LatestState.current_model)`r`n`r`n本次选中会话数: $($selectedIds.Count)`r`n每次都会先自动备份数据库和受影响的 rollout 元数据文件。"
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

$restoreLatestTrashButton.Add_Click({
  try {
    if (-not (Confirm-Action -Message '请先关闭 Codex Desktop，再继续恢复。将会恢复最新一次删除的会话，并在恢复前再做一次安全快照。' -Title '确认恢复最新删除')) {
      Append-Log '用户取消了恢复最新删除。'
      return
    }

    $result = Invoke-Backend @('--json', 'restore-trash')
    Append-Log "已恢复最新删除: $($result.restored_from)"
    Append-Log "恢复线程: $($result.restored_rows)，恢复 rollout 文件: $($result.restored_rollout_files)，冲突: $($result.rollout_conflicts)"
    Append-Log "恢复前安全快照: $($result.safety_backup)"
    Refresh-State
    [System.Windows.Forms.MessageBox]::Show('恢复完成。建议重开一次 Codex 再看历史列表。', '恢复完成', 'OK', 'Information') | Out-Null
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '恢复删除失败', 'OK', 'Error') | Out-Null
    Append-Log "恢复删除失败: $($_.Exception.Message)"
  }
})

$openTrashButton.Add_Click({
  try {
    if (-not $script:LatestState) {
      Refresh-State
    }
    $folder = $script:LatestState.trash_dir
    if (-not (Test-Path -LiteralPath $folder)) {
      New-Item -ItemType Directory -Force -Path $folder | Out-Null
    }
    Start-Process explorer.exe $folder
    Append-Log "已打开回收站目录: $folder"
  } catch {
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '打开回收站失败', 'OK', 'Error') | Out-Null
    Append-Log "打开回收站失败: $($_.Exception.Message)"
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
