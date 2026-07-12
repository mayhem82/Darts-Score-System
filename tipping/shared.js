// Bellbrook Darts Club — Tipping Module shared client + helpers.
// Loaded after the Supabase JS CDN script and config.js on every tipping page.

const supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

const CONFIG_PLACEHOLDER = SUPABASE_URL === 'YOUR_SUPABASE_PROJECT_URL';

function configWarning() {
    if (!CONFIG_PLACEHOLDER) return '';
    return '<div class="message">Tipping module is not connected yet — an admin needs to fill in tipping/config.js with the Supabase project details.</div>';
}

async function getCurrentSeason() {
    const { data, error } = await supabase
        .from('seasons')
        .select('*')
        .eq('is_current', true)
        .limit(1)
        .maybeSingle();
    if (error) throw error;
    return data;
}

async function getRounds(seasonId) {
    const { data, error } = await supabase
        .from('rounds_public')
        .select('*')
        .eq('season_id', seasonId)
        .order('round_number', { ascending: false });
    if (error) throw error;
    return data || [];
}

async function getCurrentRound(seasonId) {
    const rounds = await getRounds(seasonId);
    const now = new Date();
    const open = rounds.find(r => new Date(r.opens_at) <= now && now < new Date(r.closes_at));
    if (open) return open;
    return rounds[0] || null;
}

async function getLeagueEntrantCount(seasonId) {
    const { count, error } = await supabase
        .from('league_entrants_public')
        .select('*', { count: 'exact', head: true })
        .eq('season_id', seasonId)
        .eq('active', true);
    if (error) throw error;
    return count || 0;
}

async function submitTip(roundId, competitionType, participantName, accessCode, winner, checkout, total180s) {
    const { data, error } = await supabase.rpc('submit_tip', {
        p_round_id: roundId,
        p_competition_type: competitionType,
        p_participant_name: participantName,
        p_access_code: accessCode,
        p_winner: winner,
        p_checkout: checkout,
        p_total_180s: total180s
    });
    if (error) throw error;
    return data && data[0] ? data[0] : { ok: false, message: 'Unexpected response.' };
}

async function leagueLeaderboard(seasonId) {
    const { data, error } = await supabase.rpc('league_leaderboard', { p_season_id: seasonId });
    if (error) throw error;
    return data || [];
}

async function weeklyLeaderboard(roundId) {
    const { data, error } = await supabase.rpc('weekly_leaderboard', { p_round_id: roundId });
    if (error) throw error;
    return data || [];
}

async function roundPoints(roundId) {
    const { data, error } = await supabase.rpc('round_points', { p_round_id: roundId });
    if (error) throw error;
    return data || [];
}

async function leaguePrizePool(seasonId) {
    const { data, error } = await supabase.rpc('league_prize_pool', { p_season_id: seasonId });
    if (error) throw error;
    return (data && data.length ? data[0] : 0) || 0;
}

async function weeklyPrizePool(roundId) {
    const { data, error } = await supabase.rpc('weekly_prize_pool', { p_round_id: roundId });
    if (error) throw error;
    return (data && data.length ? data[0] : 0) || 0;
}

function money(n) {
    return '$' + Number(n || 0).toLocaleString('en-AU', { maximumFractionDigits: 0 });
}

function ordinal(n) {
    const s = ['th', 'st', 'nd', 'rd'];
    const v = n % 100;
    return n + (s[(v - 20) % 10] || s[v] || s[0]);
}

function formatCountdown(msRemaining) {
    if (msRemaining <= 0) return 'Closed';
    const totalSeconds = Math.floor(msRemaining / 1000);
    const h = Math.floor(totalSeconds / 3600);
    const m = Math.floor((totalSeconds % 3600) / 60);
    const s = totalSeconds % 60;
    const pad = x => String(x).padStart(2, '0');
    return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
}

function roundStatus(round) {
    if (!round) return { label: 'No round scheduled', cssClass: 'waiting', open: false };
    const now = new Date();
    const opens = new Date(round.opens_at);
    const closes = new Date(round.closes_at);
    if (now < opens) return { label: 'Opens Wednesday 3:30pm', cssClass: 'waiting', open: false };
    if (now >= closes) return { label: 'Tipping Closed', cssClass: 'closed', open: false };
    return { label: 'Tipping Open', cssClass: '', open: true };
}
