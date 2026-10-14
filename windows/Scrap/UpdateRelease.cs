using System.Text.Json.Nodes;
using System.Security.Cryptography;

namespace Scrap;

public static class UpdateRelease
{
    public static Version? ParseVersion(string tag)
    {
        if (tag.StartsWith("windows-", StringComparison.OrdinalIgnoreCase)) tag = tag[8..];
        if (tag.EndsWith("-windows", StringComparison.OrdinalIgnoreCase)) tag = tag[..^8];
        return Version.TryParse(tag.TrimStart('v', 'V'), out var version) ? version : null;
    }

    public static JsonNode? Latest(JsonArray releases) => releases
        .Where(r => r != null && r["draft"]?.GetValue<bool>() != true && r["prerelease"]?.GetValue<bool>() != true &&
            string.Equals(r["target_commitish"]?.ToString(), "windows-app-sdk", StringComparison.OrdinalIgnoreCase))
        .Where(r => ParseVersion(r!["tag_name"]?.ToString() ?? "") != null)
        .OrderByDescending(r => ParseVersion(r!["tag_name"]!.ToString())).FirstOrDefault();

    public static bool Verify(byte[] bytes, string digest)
    {
        if (!digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase) || digest.Length != 71) return false;
        try { return CryptographicOperations.FixedTimeEquals(Convert.FromHexString(digest[7..]), SHA256.HashData(bytes)); }
        catch (FormatException) { return false; }
    }
}
