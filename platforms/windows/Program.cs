using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;
using System.Drawing.Imaging;
using QRCoder;

namespace ClipMesh;
record Group(string name, string relay, string key, [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? transport = null, [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string[]? seeds = null) {
    [JsonIgnore] public string Id => Convert.ToHexString(SHA256.HashData(Convert.FromBase64String(key))).ToLowerInvariant();
    [JsonIgnore] public string Invitation => "clipmesh://join#" + Convert.ToBase64String(JsonSerializer.SerializeToUtf8Bytes(new { v = 1, name, relay, key, transport, seeds = seeds?.Take(16).ToArray() }, new JsonSerializerOptions { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull })).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    public static Group Parse(string invitation) {
        const string prefix = "clipmesh://join#";
        if (invitation.Length > 8192 || !invitation.StartsWith(prefix, StringComparison.Ordinal)) throw new Exception("Expected a ClipMesh invitation link.");
        string data = invitation[prefix.Length..].Replace('-', '+').Replace('_', '/'); data = data.PadRight((data.Length + 3) / 4 * 4, '=');
        using var doc = JsonDocument.Parse(Convert.FromBase64String(data)); var root = doc.RootElement;
        if (root.GetProperty("v").GetInt32() != 1) throw new Exception("Unsupported invitation version.");
        var group = JsonSerializer.Deserialize<Group>(root.GetRawText()) ?? throw new Exception("Invalid invitation.");
        if (string.IsNullOrWhiteSpace(group.name) || Encoding.UTF8.GetByteCount(group.name) > 200 || Convert.FromBase64String(group.key).Length != 32) throw new Exception("Invalid group key or name.");
        if (group.transport != null && group.transport != "p2p") throw new Exception("Unsupported group transport.");
        if (group.relay.Length == 0) { if (group.transport != "p2p") throw new Exception("A relay is required for legacy mode."); }
        else if (!Uri.TryCreate(group.relay, UriKind.Absolute, out var uri) || (uri.Scheme != "ws" && uri.Scheme != "wss") || string.IsNullOrEmpty(uri.Host) || uri.Query != "" || uri.Fragment != "" || uri.UserInfo != "" || uri.AbsolutePath != "/") throw new Exception("Invalid relay address.");
        if (group.seeds != null && (group.seeds.Length > 32 || group.seeds.Any(id => id.Length != 64 || id.Any(c => !(c is >= '0' and <= '9' or >= 'a' and <= 'f'))))) throw new Exception("Invalid paired device identities.");
        return group with { relay = group.relay.TrimEnd('/') };
    }
}
class Config {
    public int v { get; set; } = 1;
    public string device { get; set; } = Guid.NewGuid().ToString();
    public string name { get; set; } = Environment.MachineName;
    public List<Group> groups { get; set; } = [];
    public string active_group { get; set; } = "";
    public bool paused { get; set; }
}
static class Program {
    static void ProtocolSelfTest() {
        string key = Convert.ToBase64String(new byte[32]);
        var original = new Group("Independent group", "", key, "p2p", new[] { new string('a', 64) });
        var parsed = Group.Parse(original.Invitation);
        if (parsed.relay != "" || parsed.seeds?.Single() != new string('a', 64)) throw new Exception("Seeded invitation roundtrip failed");
        bool rejected = false; try { Group.Parse(new Group("invalid legacy", "", key).Invitation); } catch { rejected = true; }
        if (!rejected) throw new Exception("Empty legacy relay was accepted");
        rejected = false; try { Group.Parse((original with { seeds = new[] { "invalid" } }).Invitation); } catch { rejected = true; }
        if (!rejected) throw new Exception("Malformed endpoint identity was accepted");
    }
    [STAThread] static int Main(string[] args) {
        if (args.Contains("--protocol-self-test")) { ProtocolSelfTest(); return 0; }
        if (args.Contains("--prepare-update")) return UpdatePreparation.Run(args);
        using var mutex = new Mutex(true, "Local\\ClipMesh-Desktop", out bool created);
        bool owned = created;
        if (!owned) { try { owned = mutex.WaitOne(0); } catch (AbandonedMutexException) { owned = true; } }
        if (!owned) { InstanceControl.ActivateExisting(); return 0; }
        try {
            ApplicationConfiguration.Initialize();
            using var form = new MeshForm(); using var stopping = new CancellationTokenSource();
            form.Shown += (_, _) => { _ = InstanceControl.Serve(form, stopping.Token); };
            Application.Run(form); stopping.Cancel(); return 0;
        } finally { mutex.ReleaseMutex(); }
    }
}
class MeshForm : Form {
    [DllImport("user32.dll")] static extern bool AddClipboardFormatListener(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
    const int ClipboardUpdate = 0x031D;
    readonly string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClipMesh");
    string ConfigPath => Path.Combine(directory, "config.json");
    Config config = new(); Process? core; Process? relay; StreamWriter? input; int generation;
    string? pendingRemote; string pendingMime = "text/plain"; uint lastRemoteSequence;
    [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
    readonly Label status = new() { Text = "Create or join a group to start.", AutoSize = true, MaximumSize = new Size(550, 60) };
    readonly ComboBox groups = new() { Width = 550, DropDownStyle = ComboBoxStyle.DropDownList };
    readonly TextBox groupName = new() { Width = 550, Text = "My devices" };
    readonly TextBox relayAddress = new() { Width = 550, PlaceholderText = "선택 사항 · 예전 WebSocket 릴레이 주소" };
    readonly TextBox invitation = new() { Width = 550, PlaceholderText = "clipmesh://join#…" };
    readonly TextBox selectedInvitation = new() { Width = 550, Height = 60, ReadOnly = true, Multiline = true, ScrollBars = ScrollBars.Vertical };
    readonly CheckBox p2p = new() { Text = "Prefer P2P for this group (upgrade all devices first)", AutoSize = true };
    readonly CheckBox paused = new() { Text = "클립보드 동기화 켜기", AutoSize = true };
    readonly CheckBox host = new() { Text = "Host a LAN relay on this PC (port 47391)", AutoSize = true };
    readonly CheckBox login = new() { Text = "Windows 로그인할 때 자동 실행 · 재부팅 후 연결 복구", AutoSize = true };
    readonly NotifyIcon tray = new() { Icon = SystemIcons.Application, Text = "ClipMesh", Visible = true };
    readonly System.Windows.Forms.Timer retry = new() { Interval = 200 };
    readonly Label peerSummary = new() { AutoSize = true, MaximumSize = new Size(550, 240), Text = "연결된 기기를 확인하는 중" };
    FlowLayoutPanel advanced = null!;
    JsonElement lastConnection;
    bool refreshing; bool exiting;
    public MeshForm() {
        Text = "ClipMesh · Account-free clipboard sync"; ClientSize = new Size(610, 640); StartPosition = FormStartPosition.CenterScreen;
        Directory.CreateDirectory(directory);
        try { if (File.Exists(ConfigPath)) config = JsonSerializer.Deserialize<Config>(File.ReadAllText(ConfigPath)) ?? new(); } catch { MessageBox.Show("Could not load ClipMesh config. Check config.json before creating a new group."); }
        var panel = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new Padding(20) }; Controls.Add(panel);
        void Label(string text) => panel.Controls.Add(new Label { Text = text, AutoSize = true, MaximumSize = new Size(550, 60), Margin = new Padding(3, 12, 3, 4) });
        void Button(string text, Action action) { var button = new Button { Text = text, AutoSize = true }; button.Click += (_, _) => Safe(action); panel.Controls.Add(button); }
        panel.Controls.Add(new Label { Text = "ClipMesh", Font = new Font(SystemFonts.DefaultFont.FontFamily, 24, FontStyle.Bold), AutoSize = true });
        status.Font = new Font(SystemFonts.DefaultFont.FontFamily, 15, FontStyle.Bold); panel.Controls.Add(status);
        paused.Font = new Font(SystemFonts.DefaultFont.FontFamily, 13, FontStyle.Bold); panel.Controls.Add(paused);
        Label("켜면 이 그룹의 텍스트와 이미지를 주고받습니다. 끄면 이 PC의 송수신이 멈춥니다.");
        Label("현재 그룹"); panel.Controls.Add(groups); panel.Controls.Add(peerSummary);
        Button("다른 기기 연결 · QR 표시", ShowQR); Button("QR 이미지로 참가", JoinQR);
        Label("창을 닫아도 작업 표시줄의 숨겨진 아이콘(∧)에서 계속 실행됩니다. 완전히 끝내려면 트레이 메뉴에서 종료하세요.");
        panel.Controls.Add(login);
        Button("고급 설정 / 새 그룹 만들기 ▾", () => advanced.Visible = !advanced.Visible);
        advanced = new FlowLayoutPanel { Width = 555, AutoSize = true, FlowDirection = FlowDirection.TopDown, WrapContents = false, Visible = false };
        panel.Controls.Add(advanced);
        void AdvancedLabel(string text) => advanced.Controls.Add(new Label { Text = text, AutoSize = true, MaximumSize = new Size(545, 80), Margin = new Padding(3, 10, 3, 4) });
        void AdvancedButton(string text, Action action) { var button = new Button { Text = text, AutoSize = true }; button.Click += (_, _) => Safe(action); advanced.Controls.Add(button); }
        p2p.Text = "직접 연결 우선 (P2P) · 연결이 어려우면 릴레이 사용"; advanced.Controls.Add(p2p);
        AdvancedButton("기존 그룹을 Mac 없이 연결로 전환", () => { var group = SharingGroup(true) ?? throw new Exception("먼저 그룹을 선택하세요."); if ((group.seeds?.Length ?? 0) < 2) throw new Exception("다른 기기가 한 대 이상 연결된 뒤 전환하세요. 새 기기는 QR로 참가할 수 있습니다."); AddGroup(group); });
        AdvancedLabel("새 그룹 만들기 · 기존 기기와 연결하려면 위의 QR 참가를 사용하세요."); advanced.Controls.Add(groupName); advanced.Controls.Add(relayAddress);
        host.Text = "이 PC에서 발견용 릴레이 실행 (포트 47391)"; advanced.Controls.Add(host);
        AdvancedButton("새 그룹 만들기", () => AddGroup(Group.Parse(new Group(groupName.Text, relayAddress.Text, Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)), "p2p").Invitation)));
        AdvancedLabel("초대 링크로 참가"); advanced.Controls.Add(invitation);
        AdvancedButton("초대 링크로 참가", () => { AddGroup(Group.Parse(invitation.Text.Trim())); invitation.Clear(); });
        AdvancedLabel("현재 그룹 초대 링크 · 비밀키 포함, 신뢰하는 기기에만 공유하세요."); advanced.Controls.Add(selectedInvitation);
        var menu = new ContextMenuStrip(); menu.Items.Add("ClipMesh 열기…", null, (_, _) => { Show(); WindowState = FormWindowState.Normal; Activate(); });
        menu.Items.Add("ClipMesh 완전히 종료", null, (_, _) => { exiting = true; Close(); }); tray.ContextMenuStrip = menu; tray.DoubleClick += (_, _) => { Show(); Activate(); };
        groups.SelectedIndexChanged += (_, _) => { if (refreshing || groups.SelectedIndex < 0) return; Safe(() => { config.active_group = config.groups[groups.SelectedIndex].Id; Save(); RefreshGroups(); StartCore(); }); };
        paused.CheckedChanged += (_, _) => { if (refreshing) return; Safe(() => { config.paused = !paused.Checked; pendingRemote = null; lastRemoteSequence = 0; Save(); Send(new { op = "pause", paused = config.paused }); RenderConnection(); }); };
        p2p.CheckedChanged += (_, _) => { if (refreshing) return; Safe(() => { int i = config.groups.FindIndex(g => g.Id == config.active_group); if (i < 0) return; if (!p2p.Checked && config.groups[i].relay.Length == 0) { refreshing = true; p2p.Checked = true; refreshing = false; throw new Exception("기기 간 자동 연결 그룹입니다. 끄려면 위의 동기화 스위치를 사용하세요."); } config.groups[i] = config.groups[i] with { transport = p2p.Checked ? "p2p" : null }; Save(); RefreshGroups(); StartCore(); }); };
        host.CheckedChanged += (_, _) => Safe(() => { File.WriteAllText(Path.Combine(directory, "host-relay"), host.Checked.ToString()); if (host.Checked) StartRelay(); else { Stop(relay); relay = null; } });
        using (var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) login.Checked = key?.GetValue("ClipMesh") != null;
        login.CheckedChanged += (_, _) => Safe(() => { using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"); if (login.Checked) key.SetValue("ClipMesh", $"\"{Environment.ProcessPath}\" --background"); else key.DeleteValue("ClipMesh", false); });
        retry.Tick += (_, _) => { if (pendingRemote != null) ApplyRemote(); }; retry.Start();
        RefreshGroups();
        if (File.Exists(Path.Combine(directory, "host-relay")) && File.ReadAllText(Path.Combine(directory, "host-relay")) == "True") host.Checked = true;
        Shown += (_, _) => { StartCore(); if (Environment.GetCommandLineArgs().Contains("--background") && config.groups.Count > 0) Hide(); };
    }
    public void ShowSettings() { Show(); WindowState = FormWindowState.Normal; Activate(); }
    public void ExitForUpdate() { exiting = true; Close(); }
    static void Safe(Action action) { try { action(); } catch (Exception e) { MessageBox.Show(e.Message, "ClipMesh"); } }
    void Save() {
        string temporary = ConfigPath + ".tmp"; File.WriteAllText(temporary, JsonSerializer.Serialize(config)); File.Move(temporary, ConfigPath, true);
        // LocalAppData inherits the current user's ACL; no shared ProgramData keys.
    }
    void RefreshGroups() { refreshing = true; groups.Items.Clear(); groups.Items.AddRange(config.groups.Select(g => (object)g.name).ToArray()); groups.SelectedIndex = config.groups.FindIndex(g => g.Id == config.active_group); selectedInvitation.Text = groups.SelectedIndex >= 0 ? SharingGroup(false)?.Invitation ?? "동기화를 켜면 연결용 QR이 준비됩니다." : ""; paused.Checked = !config.paused; p2p.Checked = config.groups.FirstOrDefault(g => g.Id == config.active_group)?.transport == "p2p"; refreshing = false; RenderConnection(); }
    void AddGroup(Group group) { int i = config.groups.FindIndex(g => g.Id == group.Id); if (i < 0) config.groups.Add(group); else config.groups[i] = group; config.active_group = group.Id; Save(); RefreshGroups(); StartCore(); }
    string CorePath => Path.Combine(AppContext.BaseDirectory, "clipmesh-core.exe");
    void StartRelay() {
        if (relay is { HasExited: false }) return;
        var info = new ProcessStartInfo(CorePath) { UseShellExecute = false, CreateNoWindow = true }; info.ArgumentList.Add("relay"); info.ArgumentList.Add("--listen"); info.ArgumentList.Add("0.0.0.0:47391");
        relay = Process.Start(info) ?? throw new Exception("Could not start relay.");
    }
    static void Stop(Process? process) { try { if (process is { HasExited: false }) process.Kill(true); process?.Dispose(); } catch { } }
    void StartCore() {
        int token = ++generation; lastConnection = default; RenderConnection(); input = null; Stop(core); core = null; pendingRemote = null; lastRemoteSequence = 0;
        if (config.groups.Count == 0) return; Save();
        var info = new ProcessStartInfo(CorePath) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8 };
        info.ArgumentList.Add("run"); info.ArgumentList.Add("--config"); info.ArgumentList.Add(ConfigPath);
        var process = new Process { StartInfo = info, EnableRaisingEvents = true };
        process.OutputDataReceived += (_, e) => { if (e.Data == null || IsDisposed || !IsHandleCreated) return; try { var doc = JsonDocument.Parse(e.Data); BeginInvoke(() => { using (doc) { if (token == generation) Receive(doc.RootElement); } }); } catch { } };
        process.ErrorDataReceived += (_, _) => { }; // Drain stderr without recording clipboard content.
        process.Exited += async (_, _) => { await Task.Delay(3000); if (IsDisposed || !IsHandleCreated) return; BeginInvoke(() => { if (token == generation && !exiting) Safe(StartCore); }); };
        process.Start(); input = process.StandardInput; input.AutoFlush = true; core = process; process.BeginOutputReadLine(); process.BeginErrorReadLine(); status.Text = "Connecting…";
    }
    void Send(object value) { if (input == null) return; try { input.WriteLine(JsonSerializer.Serialize(value)); } catch { status.Text = "Sync engine disconnected"; } }
    void Receive(JsonElement root) {
        if (!root.TryGetProperty("type", out var type)) return;
        if (type.GetString() == "clipboard" && !config.paused) { var ev = root.GetProperty("event"); pendingRemote = ev.GetProperty("text").GetString(); pendingMime = ev.GetProperty("mime").GetString() ?? "text/plain"; ApplyRemote(); }
        else if (type.GetString() == "status") { lastConnection = root.Clone(); RenderConnection(); selectedInvitation.Text = SharingGroup(false)?.Invitation ?? "동기화를 켜면 연결용 QR이 준비됩니다."; }
        else if (type.GetString() == "error") status.Text = root.GetProperty("message").GetString();
    }
    void RenderConnection() {
        paused.Enabled = config.groups.Count > 0;
        if (config.groups.Count == 0) { status.Text = "먼저 기기를 연결하세요"; peerSummary.Text = "QR 이미지로 참가하거나 고급 설정에서 그룹을 만드세요."; return; }
        bool valid = lastConnection.ValueKind == JsonValueKind.Object;
        bool connected = valid && lastConnection.TryGetProperty("connected", out var c) && c.ValueKind == JsonValueKind.True;
        string mode = valid && lastConnection.TryGetProperty("transport", out var t) ? t.GetString() ?? "websocket" : "websocket";
        int? count = valid && (lastConnection.TryGetProperty("connected_peer_count", out var p) || lastConnection.TryGetProperty("peers", out p)) && p.TryGetInt32(out var n) ? n : null;
        string route = mode == "p2p-direct" ? "직접 연결" : mode == "iroh-relay" ? "암호화 릴레이" : "발견용 서버 연결";
        status.Text = config.paused ? "동기화 꺼짐" : !connected ? "연결 중…" : count == 0 ? "기기를 찾는 중…" : "동기화 켜짐 · " + route;
        peerSummary.Text = count.HasValue ? $"연결된 다른 기기 {count}대 · 이 기기 포함 {count + 1}대" : connected ? "릴레이 연결됨 · 개별 기기 수는 이 모드에서 확인할 수 없습니다." : "네트워크 연결을 기다리고 있습니다.";
        if (count == 0) peerSummary.Text += "\n다른 기기에서 같은 그룹과 동기화 켜짐을 확인하세요.";
        if (valid && lastConnection.TryGetProperty("peer_details", out var list) && list.ValueKind == JsonValueKind.Array) {
            foreach (var peer in list.EnumerateArray()) {
                string name = peer.TryGetProperty("name", out var nameValue) ? nameValue.GetString() ?? "" : "";
                if (string.IsNullOrWhiteSpace(name)) name = "이름 없는 기기"; if (name.Length > 60) name = name[..60];
                string selected = peer.TryGetProperty("route", out var path) ? path.GetString() ?? "" : "";
                peerSummary.Text += "\n• " + name + " · " + (selected == "direct" ? "직접" : selected == "relay" ? "릴레이" : "경로 확인 중");
            }
        }
        if (config.paused) peerSummary.Text += "\n네트워크가 연결되어 있어도 클립보드는 보내거나 받지 않습니다.";
    }
    const int MaxPNG = 8 * 1024 * 1024;
    static bool ValidPNG(byte[] bytes) {
        if (bytes.Length < 24 || bytes.Length > MaxPNG || !bytes.AsSpan(0, 8).SequenceEqual(new byte[] {137,80,78,71,13,10,26,10})) return false;
        uint w = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(16,4));
        uint h = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(20,4));
        return w > 0 && h > 0 && w <= 16384 && h <= 16384 && (ulong)w * h <= 40_000_000;
    }
    void ApplyRemote() {
        if (pendingRemote == null || config.paused) return;
        try {
            if (pendingMime == "image/png") {
                var bytes = Convert.FromBase64String(pendingRemote);
                if (!ValidPNG(bytes)) { pendingRemote = null; status.Text = "Rejected invalid or oversized image"; return; }
                using var stream = new MemoryStream(bytes);
                using var image = Image.FromStream(stream, true, true);
                using var bitmap = new Bitmap(image);
                var value = new DataObject();
                value.SetData("PNG", false, new MemoryStream(bytes)); value.SetData(DataFormats.Bitmap, true, bitmap);
                Clipboard.SetDataObject(value, true);
            } else if (pendingMime == "text/plain") {
                if (pendingRemote.Length == 0) Clipboard.Clear(); else Clipboard.SetText(pendingRemote, TextDataFormat.UnicodeText);
            }
            lastRemoteSequence = GetClipboardSequenceNumber(); pendingRemote = null;
        } catch (ExternalException) { }
        catch (Exception) { pendingRemote = null; status.Text = "Image could not be decoded"; }
    }
    protected override void OnHandleCreated(EventArgs e) { base.OnHandleCreated(e); AddClipboardFormatListener(Handle); }
    protected override void OnHandleDestroyed(EventArgs e) { RemoveClipboardFormatListener(Handle); base.OnHandleDestroyed(e); }
    protected override void WndProc(ref Message m) {
        base.WndProc(ref m);
        if (m.Msg != ClipboardUpdate || config.paused || core is not { HasExited: false } || pendingRemote != null) return;
        if (GetClipboardSequenceNumber() == lastRemoteSequence) return;
        try {
            if (Clipboard.ContainsData("PNG")) {
                var value = Clipboard.GetData("PNG"); byte[]? data = value as byte[];
                if (value is Stream png) {
                    using var collected = new MemoryStream(); var buffer = new byte[65536]; int count;
                    while ((count = png.Read(buffer, 0, Math.Min(buffer.Length, MaxPNG + 1 - (int)collected.Length))) > 0) { collected.Write(buffer, 0, count); if (collected.Length > MaxPNG) break; }
                    if (collected.Length <= MaxPNG) data = collected.ToArray();
                }
                if (data != null && ValidPNG(data)) { Send(new { op = "copy_image", data = Convert.ToBase64String(data) }); return; }
                // Applications may advertise PNG but expose only their bitmap representation.
                if (!Clipboard.ContainsImage()) return;
            }
            if (Clipboard.ContainsImage()) {
                using var image = Clipboard.GetImage();
                if (image == null || image.Width > 16384 || image.Height > 16384 || (long)image.Width * image.Height > 40_000_000) return;
                using var bytes = new MemoryStream(); image.Save(bytes, ImageFormat.Png);
                if (bytes.Length <= MaxPNG) Send(new { op = "copy_image", data = Convert.ToBase64String(bytes.ToArray()) });
                else status.Text = "Image exceeds 8 MiB";
                return;
            }
            if (!Clipboard.ContainsText(TextDataFormat.UnicodeText)) return;
            var text = Clipboard.GetText(TextDataFormat.UnicodeText);
            if (!text.Contains("clipmesh://join#", StringComparison.Ordinal) && Encoding.UTF8.GetByteCount(text) <= 1048576) Send(new { op = "copy", text });
        } catch (ExternalException) { }
        catch (Exception) { status.Text = "Clipboard image could not be read"; }
    }
    Group? SharingGroup(bool requireReady) {
        var group = config.groups.FirstOrDefault(g => g.Id == config.active_group);
        if (group == null || group.transport != "p2p") return group;
        if (lastConnection.ValueKind == JsonValueKind.Object && lastConnection.TryGetProperty("group", out var statusGroup) && statusGroup.GetString() == config.active_group && lastConnection.TryGetProperty("self_id", out var own) && lastConnection.TryGetProperty("seed_ids", out var ids) && ids.ValueKind == JsonValueKind.Array) {
            var seeds = ids.EnumerateArray().Select(i => i.GetString() ?? "").Take(16).ToArray();
            if (seeds.Contains(own.GetString())) return group with { seeds = seeds, relay = "" };
        }
        if (requireReady || group.transport == "p2p") {
            if (requireReady) throw new Exception("동기화를 켜고 기기 연결 신원이 준비된 뒤 QR을 다시 여세요.");
            return null;
        }
        return group;
    }
    void ShowQR() {
        var group = SharingGroup(true); if (group == null) return;
        using var generator = new QRCodeGenerator(); using var data = generator.CreateQrCode(group.Invitation, QRCodeGenerator.ECCLevel.M);
        using var code = new PngByteQRCode(data); using var bytes = new MemoryStream(code.GetGraphic(8));
        using var bitmap = new Bitmap(bytes);
        using var dialog = new Form { Text = "Scan to join " + group.name, ClientSize = new Size(470, 510), StartPosition = FormStartPosition.CenterParent };
        dialog.Controls.Add(new PictureBox { Image = bitmap, SizeMode = PictureBoxSizeMode.Zoom, Dock = DockStyle.Fill, BackColor = Color.White });
        dialog.Controls.Add(new Label { Text = "Contains your group secret. Show only to trusted devices.", Dock = DockStyle.Bottom, Height = 40, TextAlign = ContentAlignment.MiddleCenter });
        dialog.ShowDialog(this);
    }
    void JoinQR() {
        using var picker = new OpenFileDialog { Filter = "QR images|*.png;*.jpg;*.jpeg;*.bmp", CheckFileExists = true };
        if (picker.ShowDialog(this) != DialogResult.OK) return;
        if (new FileInfo(picker.FileName).Length > 20 * 1024 * 1024) throw new Exception("QR image is too large.");
        using var source = Image.FromFile(picker.FileName);
        if ((long)source.Width * source.Height > 40_000_000) throw new Exception("QR image is too large.");
        using var bitmap = new Bitmap(source.Width, source.Height, PixelFormat.Format32bppArgb);
        using (var graphics = Graphics.FromImage(bitmap)) graphics.DrawImage(source, 0, 0, source.Width, source.Height);
        var bits = bitmap.LockBits(new Rectangle(0, 0, bitmap.Width, bitmap.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        byte[] pixels = new byte[bitmap.Width * bitmap.Height * 4];
        try { for (int y = 0; y < bitmap.Height; y++) Marshal.Copy(IntPtr.Add(bits.Scan0, y * bits.Stride), pixels, y * bitmap.Width * 4, bitmap.Width * 4); }
        finally { bitmap.UnlockBits(bits); }
        var luminance = new ZXing.RGBLuminanceSource(pixels, bitmap.Width, bitmap.Height, ZXing.RGBLuminanceSource.BitmapFormat.BGRA32);
        var reader = new ZXing.BarcodeReaderGeneric { Options = new ZXing.Common.DecodingOptions { PossibleFormats = new[] { ZXing.BarcodeFormat.QR_CODE }, TryHarder = true } };
        var result = reader.Decode(luminance) ?? throw new Exception("No ClipMesh QR found in this image.");
        AddGroup(Group.Parse(result.Text));
    }
    protected override void OnFormClosing(FormClosingEventArgs e) { if (!exiting && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); return; } generation++; retry.Stop(); input = null; Stop(core); Stop(relay); tray.Dispose(); base.OnFormClosing(e); }
}
