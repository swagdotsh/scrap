using System.Text.Json;
using Windows.Security.Credentials;

namespace Scrap;

public static class LocalStore
{
    private static readonly string Folder = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Scrap");
    public static T Load<T>(string name, T fallback)
    {
        var path = Path.Combine(Folder, name);
        return File.Exists(path) ? JsonSerializer.Deserialize<T>(File.ReadAllText(path)) ?? fallback : fallback;
    }
    public static void Save<T>(string name, T value)
    {
        Directory.CreateDirectory(Folder);
        var path = Path.Combine(Folder, name);
        File.WriteAllText(path + ".tmp", JsonSerializer.Serialize(value));
        File.Move(path + ".tmp", path, true);
    }
    public static (string User, string Secret)? Credential(string resource)
    {
        try
        {
            var item = new PasswordVault().FindAllByResource(resource).FirstOrDefault();
            if (item == null) return null;
            item.RetrievePassword();
            return (item.UserName, item.Password);
        }
        catch (Exception e) when (e.HResult == unchecked((int)0x80070490)) { return null; }
    }
    public static void SaveCredential(string resource, string user, string secret)
    {
        ClearCredential(resource);
        new PasswordVault().Add(new PasswordCredential(resource, user, secret));
    }
    public static void ClearCredential(string resource)
    {
        var existing = Credential(resource);
        if (existing is { } item) new PasswordVault().Remove(new PasswordCredential(resource, item.User, item.Secret));
    }
}
