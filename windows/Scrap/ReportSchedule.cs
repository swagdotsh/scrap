namespace Scrap;

public static class ReportSchedule
{
    public static readonly TimeZoneInfo Zurich = FindZurich();

    private static TimeZoneInfo FindZurich()
    {
        try { return TimeZoneInfo.FindSystemTimeZoneById("Europe/Zurich"); }
        catch (TimeZoneNotFoundException) { return TimeZoneInfo.FindSystemTimeZoneById("W. Europe Standard Time"); }
    }

    public static DateTimeOffset Latest(DateTimeOffset now)
    {
        var local = TimeZoneInfo.ConvertTime(now, Zurich).DateTime;
        var friday = local.Date.AddDays(-(((int)local.DayOfWeek - (int)DayOfWeek.Friday + 7) % 7)).AddHours(16);
        if (friday > local) friday = friday.AddDays(-7);
        return At(friday);
    }

    public static DateTimeOffset Next(DateTimeOffset now) => At(TimeZoneInfo.ConvertTime(Latest(now), Zurich).DateTime.AddDays(7));

    private static DateTimeOffset At(DateTime zurichLocal) =>
        new(TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(zurichLocal, DateTimeKind.Unspecified), Zurich), TimeSpan.Zero);

    public static string Description(DateTimeOffset now, TimeZoneInfo local)
    {
        var next = Next(now);
        var zone = Zurich.IsDaylightSavingTime(next) ? "Central European Summer Time" : "Central European Time";
        var mine = TimeZoneInfo.ConvertTime(next, local);
        var time = mine.ToString("t");
        return $"Every Friday at 16:00 {zone}, which is {(mine.DayOfWeek == DayOfWeek.Friday ? time : mine.ToString("dddd") + " " + time)} for you.";
    }
}
