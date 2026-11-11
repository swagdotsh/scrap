using System.Buffers.Binary;
using System.IO.Pipes;
using System.Text;
using System.Text.Json.Nodes;

namespace Scrap;

/// Minimal client for the local Discord RPC pipe (`\\.\pipe\discord-ipc-N`).
/// Frames are a little-endian opcode and length followed by a JSON payload.
public sealed class DiscordIpcConnection : IDisposable
{
    public enum Opcode : uint { Handshake = 0, Frame = 1, Close = 2, Ping = 3, Pong = 4 }

    public abstract record Event;
    public sealed record Ready(string? Username) : Event;
    public sealed record Closed(string? Reason) : Event;
    public sealed record Error(int? Code, string Message) : Event;

    /// Called on a background thread. Set once, before connecting.
    public Action<Event>? OnEvent { get; set; }
    private readonly SemaphoreSlim writeLock = new(1, 1);
    private NamedPipeClientStream? pipe;
    private CancellationTokenSource? reading;
    private int connecting;

    public bool IsOpen => pipe != null;

    public async Task ConnectAsync(string clientId)
    {
        if (pipe != null || Interlocked.Exchange(ref connecting, 1) == 1) return;
        try
        {
            for (var index = 0; index < 10; index++)
            {
                var candidate = new NamedPipeClientStream(".", $"discord-ipc-{index}", PipeDirection.InOut, PipeOptions.Asynchronous);
                try { await candidate.ConnectAsync(250); }
                catch { candidate.Dispose(); continue; }
                pipe = candidate;
                reading = new CancellationTokenSource();
                _ = ReadAsync(candidate, reading.Token);
                await WriteAsync(Opcode.Handshake, new JsonObject { ["v"] = 1, ["client_id"] = clientId });
                return;
            }
            OnEvent?.Invoke(new Closed(null));
        }
        finally { Volatile.Write(ref connecting, 0); }
    }

    public Task SetActivityAsync(JsonObject? activity)
    {
        var args = new JsonObject { ["pid"] = Environment.ProcessId };
        if (activity != null) args["activity"] = activity;
        return WriteAsync(Opcode.Frame, new JsonObject { ["cmd"] = "SET_ACTIVITY", ["args"] = args, ["nonce"] = Guid.NewGuid().ToString() });
    }

    public void Disconnect() => Teardown(pipe, null, false);

    // Framing

    public static byte[] Encode(Opcode opcode, JsonObject payload)
    {
        var json = Encoding.UTF8.GetBytes(payload.ToJsonString());
        var data = new byte[8 + json.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(data, (uint)opcode);
        BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(4), (uint)json.Length);
        json.CopyTo(data, 8);
        return data;
    }

    /// Removes and returns every complete frame at the start of `buffer`.
    public static List<(uint Opcode, JsonObject Payload)> DecodeFrames(List<byte> buffer)
    {
        var frames = new List<(uint, JsonObject)>();
        while (buffer.Count >= 8)
        {
            var header = buffer.GetRange(0, 8).ToArray();
            var opcode = BinaryPrimitives.ReadUInt32LittleEndian(header);
            var length = (int)BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4));
            if (buffer.Count < 8 + length) break;
            var body = buffer.GetRange(8, length).ToArray();
            buffer.RemoveRange(0, 8 + length);
            JsonObject payload;
            try { payload = JsonNode.Parse(body) as JsonObject ?? []; }
            catch { payload = []; }
            frames.Add((opcode, payload));
        }
        return frames;
    }

    private async Task WriteAsync(Opcode opcode, JsonObject payload)
    {
        var stream = pipe;
        if (stream == null) return;
        await writeLock.WaitAsync();
        try
        {
            await stream.WriteAsync(Encode(opcode, payload));
            await stream.FlushAsync();
        }
        catch { Teardown(stream, "Lost connection to Discord.", true); }
        finally { writeLock.Release(); }
    }

    private async Task ReadAsync(NamedPipeClientStream stream, CancellationToken cancel)
    {
        var buffer = new List<byte>();
        var chunk = new byte[16 * 1024];
        try
        {
            while (!cancel.IsCancellationRequested)
            {
                var count = await stream.ReadAsync(chunk, cancel);
                if (count <= 0) break;
                buffer.AddRange(chunk.AsSpan(0, count));
                foreach (var (opcode, payload) in DecodeFrames(buffer))
                {
                    switch ((Opcode)opcode)
                    {
                        case Opcode.Frame: Handle(payload); break;
                        case Opcode.Ping: await WriteAsync(Opcode.Pong, payload); break;
                        case Opcode.Close: Teardown(stream, payload["message"]?.ToString(), true); return;
                    }
                }
            }
        }
        catch { }
        Teardown(stream, null, !cancel.IsCancellationRequested);
    }

    private void Handle(JsonObject payload)
    {
        var data = payload["data"];
        var name = payload["evt"]?.ToString();
        if (name == "READY")
        {
            var user = data?["user"];
            var display = user?["global_name"]?.ToString();
            OnEvent?.Invoke(new Ready(string.IsNullOrEmpty(display) ? user?["username"]?.ToString() : display));
        }
        else if (name == "ERROR")
            OnEvent?.Invoke(new Error(int.TryParse(data?["code"]?.ToString(), out var code) ? code : null, data?["message"]?.ToString() ?? "Discord rejected the activity."));
    }

    /// Closes `stream` if it's still the open pipe; reports it at most once.
    private void Teardown(NamedPipeClientStream? stream, string? reason, bool notify)
    {
        if (stream == null || Interlocked.CompareExchange(ref pipe, null, stream) != stream) return;
        reading?.Cancel();
        stream.Dispose();
        if (notify) OnEvent?.Invoke(new Closed(reason));
    }

    public void Dispose() => Disconnect();
}
