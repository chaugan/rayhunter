<script lang="ts">
    import { get_manifest, get_system_stats, get_signal_quality, get_config, req } from '$lib/utils.svelte';
    import type { SystemStats } from '$lib/systemStats';
    import type { SignalQuality } from '$lib/signalQuality';
    import type { Config } from '$lib/utils.svelte';
    import { getSignalBars, getSignalColor, getSignalLevel } from '$lib/signalQuality';

    let system_stats: SystemStats | undefined = $state(undefined);
    let signal_quality: SignalQuality | null = $state(null);
    let current_recording: boolean = $state(false);
    let recording_start: Date | null = $state(null);
    let warning_counts = $state({ high: 0, medium: 0, low: 0, info: 0 });
    let total_rows = $state(0);
    let clock = $state('');
    let recording_duration = $state('');
    let loaded = $state(false);
    let connection_ok = $state(true);
    let config: Config | null = $state(null);

    // Threat level derived from warning counts
    type ThreatLevel = 'CLEAR' | 'INFO' | 'ELEVATED' | 'HIGH';
    let threat_level: ThreatLevel = $derived.by(() => {
        if (warning_counts.high > 0) return 'HIGH';
        if (warning_counts.medium > 0 || warning_counts.low > 0) return 'ELEVATED';
        if (warning_counts.info > 0) return 'INFO';
        return 'CLEAR';
    });
    let threat_color = $derived.by(() => {
        switch (threat_level) {
            case 'HIGH': return '#ef4444';
            case 'ELEVATED': return '#f97316';
            case 'INFO': return '#3b82f6';
            default: return '#22c55e';
        }
    });

    // Active analyzer definitions
    const ANALYZERS: { key: string; name: string; icon: string; desc: string }[] = [
        { key: 'imsi_requested', name: 'IMSI Intercept', icon: 'ID', desc: 'Detects suspicious identity requests' },
        { key: 'connection_redirect_2g_downgrade', name: '2G Downgrade', icon: '2G', desc: 'Forced downgrade to insecure 2G' },
        { key: 'lte_sib6_and_7_downgrade', name: 'SIB Downgrade', icon: 'SB', desc: 'Priority reselection to 2G/3G' },
        { key: 'null_cipher', name: 'Null Cipher', icon: 'NC', desc: 'Unencrypted RRC connection' },
        { key: 'nas_null_cipher', name: 'NAS Cipher', icon: 'NA', desc: 'Unencrypted NAS signaling' },
        { key: 'incomplete_sib', name: 'Malformed SIB', icon: 'SI', desc: 'Incomplete system info broadcast' },
        { key: 'imsi_exposing_reject', name: 'GUTI Delete', icon: 'GD', desc: 'Forced GUTI deletion / IMSI exposure' },
        { key: 'imsi_exposure_rate', name: 'Exposure Rate', icon: 'ER', desc: 'IMSI exposure rate monitoring' },
    ];

    // Chart data buffers (rolling window of recent samples)
    const MAX_SAMPLES = 60;
    let rsrp_history: { t: number; v: number }[] = $state([]);
    let sinr_history: { t: number; v: number }[] = $state([]);
    let rsrq_history: { t: number; v: number }[] = $state([]);

    function push_sample(arr: { t: number; v: number }[], value: number) {
        const now = Date.now();
        const next = [...arr, { t: now, v: value }];
        if (next.length > MAX_SAMPLES) next.shift();
        return next;
    }

    // Year 2020 as epoch seconds — if start_time is before this, the modem clock isn't set yet
    const CLOCK_VALID_THRESHOLD = new Date('2020-01-01').getTime();

    function update_clock() {
        clock = new Date().toLocaleTimeString();
        if (recording_start && recording_start.getTime() > CLOCK_VALID_THRESHOLD) {
            const elapsed = Math.floor((Date.now() - recording_start.getTime()) / 1000);
            const h = Math.floor(elapsed / 3600);
            const m = Math.floor((elapsed % 3600) / 60);
            const s = elapsed % 60;
            recording_duration = `${h}h ${String(m).padStart(2, '0')}m ${String(s).padStart(2, '0')}s`;
        } else {
            recording_duration = '';
        }
    }

    // SVG sparkline builder
    function build_polyline(
        data: { t: number; v: number }[],
        width: number,
        height: number,
        min_v: number,
        max_v: number,
    ): string {
        if (data.length < 2) return '';
        const range = max_v - min_v || 1;
        const pad = 2;
        const usable_h = height - pad * 2;
        const usable_w = width - pad * 2;
        return data
            .map((d, i) => {
                const x = pad + (i / (data.length - 1)) * usable_w;
                const y = pad + usable_h - ((d.v - min_v) / range) * usable_h;
                return `${x.toFixed(1)},${y.toFixed(1)}`;
            })
            .join(' ');
    }

    function chart_min(data: { t: number; v: number }[], fallback: number): number {
        if (data.length === 0) return fallback;
        return Math.min(...data.map((d) => d.v));
    }
    function chart_max(data: { t: number; v: number }[], fallback: number): number {
        if (data.length === 0) return fallback;
        return Math.max(...data.map((d) => d.v));
    }
    function chart_last(data: { t: number; v: number }[]): number | null {
        return data.length > 0 ? data[data.length - 1].v : null;
    }

    // Quality zone definitions for chart backgrounds
    type ChartZone = { min: number; max: number; color: string; label: string };

    const RSRP_ZONES: ChartZone[] = [
        { min: -130, max: -110, color: 'rgba(239, 68, 68, 0.18)', label: 'Poor' },
        { min: -110, max: -100, color: 'rgba(249, 115, 22, 0.18)', label: 'Weak' },
        { min: -100, max: -90, color: 'rgba(234, 179, 8, 0.18)', label: 'Fair' },
        { min: -90, max: -80, color: 'rgba(132, 204, 22, 0.18)', label: 'Good' },
        { min: -80, max: -60, color: 'rgba(34, 197, 94, 0.18)', label: 'Excellent' },
    ];

    const SINR_ZONES: ChartZone[] = [
        { min: -10, max: 0, color: 'rgba(239, 68, 68, 0.18)', label: 'Poor' },
        { min: 0, max: 13, color: 'rgba(234, 179, 8, 0.18)', label: 'Fair' },
        { min: 13, max: 20, color: 'rgba(132, 204, 22, 0.18)', label: 'Good' },
        { min: 20, max: 35, color: 'rgba(34, 197, 94, 0.18)', label: 'Excellent' },
    ];

    const RSRQ_ZONES: ChartZone[] = [
        { min: -25, max: -20, color: 'rgba(239, 68, 68, 0.18)', label: 'Poor' },
        { min: -20, max: -15, color: 'rgba(249, 115, 22, 0.18)', label: 'Weak' },
        { min: -15, max: -10, color: 'rgba(234, 179, 8, 0.18)', label: 'Fair' },
        { min: -10, max: -3, color: 'rgba(34, 197, 94, 0.18)', label: 'Good' },
    ];

    const RSRP_RANGE = { min: -130, max: -60 };
    const SINR_RANGE = { min: -10, max: 35 };
    const RSRQ_RANGE = { min: -25, max: -3 };

    const RSRP_TOOLTIP = 'Reference Signal Received Power — measures signal strength from the cell tower. Higher (less negative) = stronger signal.\nExcellent: > -80 dBm | Good: -80 to -90 | Fair: -90 to -100 | Weak: -100 to -110 | Poor: < -110';
    const SINR_TOOLTIP = 'Signal to Interference-plus-Noise Ratio — signal quality relative to background noise and interference. Higher = cleaner signal.\nExcellent: > 20 dB | Good: 13 to 20 | Fair: 0 to 13 | Poor: < 0';
    const RSRQ_TOOLTIP = 'Reference Signal Received Quality — signal quality factoring in resource block utilization. Higher (less negative) = better.\nGood: > -10 dB | Fair: -10 to -15 | Weak: -15 to -20 | Poor: < -20';

    interface ZoneRect {
        y: number;
        h: number;
        color: string;
        label: string;
        ly: number;
    }

    function compute_zones(zones: ChartZone[], chart_min: number, chart_max: number): { rects: ZoneRect[]; boundaries: number[] } {
        const pad = 2;
        const usable = 76;
        const range = chart_max - chart_min;
        const rects = zones.map((z) => {
            const cmax = Math.min(z.max, chart_max);
            const cmin = Math.max(z.min, chart_min);
            const yt = pad + usable - ((cmax - chart_min) / range) * usable;
            const yb = pad + usable - ((cmin - chart_min) / range) * usable;
            return { y: yt, h: yb - yt, color: z.color, label: z.label, ly: yt + (yb - yt) / 2 };
        });
        const boundaries = rects.slice(0, -1).map((r) => r.y);
        return { rects, boundaries };
    }

    const rsrp_zones = compute_zones(RSRP_ZONES, RSRP_RANGE.min, RSRP_RANGE.max);
    const sinr_zones = compute_zones(SINR_ZONES, SINR_RANGE.min, SINR_RANGE.max);
    const rsrq_zones = compute_zones(RSRQ_ZONES, RSRQ_RANGE.min, RSRQ_RANGE.max);

    function getSinrColor(sinr: number): string {
        if (sinr >= 20) return '#22c55e';
        if (sinr >= 13) return '#84cc16';
        if (sinr >= 0) return '#eab308';
        return '#ef4444';
    }

    function getRsrqColor(rsrq: number): string {
        if (rsrq >= -10) return '#22c55e';
        if (rsrq >= -15) return '#eab308';
        if (rsrq >= -20) return '#f97316';
        return '#ef4444';
    }

    let sinr_color = $derived(signal_quality ? getSinrColor(signal_quality.serving_cell.sinr) : '#64748b');
    let rsrq_color = $derived(signal_quality ? getRsrqColor(signal_quality.serving_cell.rsrq) : '#64748b');

    let bars = $derived(signal_quality ? getSignalBars(signal_quality.serving_cell.rsrp) : 0);
    let color = $derived(signal_quality ? getSignalColor(signal_quality.serving_cell.rsrp) : '#6b7280');
    let level = $derived(signal_quality ? getSignalLevel(signal_quality.serving_cell.rsrp) : 'No Signal');

    let disk_percent_num = $derived.by(() => {
        if (!system_stats) return 0;
        return parseInt(system_stats.disk_stats.used_percent) || 0;
    });

    let disk_color = $derived.by(() => {
        if (disk_percent_num > 90) return '#ef4444';
        if (disk_percent_num > 75) return '#f97316';
        if (disk_percent_num > 50) return '#eab308';
        return '#22c55e';
    });

    // Chart derived values
    let rsrp_line = $derived(
        build_polyline(rsrp_history, 280, 80, RSRP_RANGE.min, RSRP_RANGE.max),
    );
    let sinr_line = $derived(
        build_polyline(sinr_history, 280, 80, SINR_RANGE.min, SINR_RANGE.max),
    );
    let rsrq_line = $derived(
        build_polyline(rsrq_history, 280, 80, RSRQ_RANGE.min, RSRQ_RANGE.max),
    );

    function is_analyzer_active(key: string): boolean {
        if (!config) return false;
        return (config.analyzers as Record<string, boolean>)[key] ?? false;
    }

    async function fetch_analysis_counts() {
        try {
            const json = JSON.parse(await req('GET', '/api/analysis-counts/live'));
            warning_counts = {
                high: json.high || 0,
                medium: json.medium || 0,
                low: json.low || 0,
                info: json.informational || 0,
            };
            total_rows = json.total_rows || 0;
        } catch {
            // Live recording may not exist
        }
    }

    $effect(() => {
        update_clock();
        const clock_interval = setInterval(update_clock, 1000);

        // Fetch config once
        get_config().then((c) => (config = c)).catch(() => {});

        const data_interval = setInterval(async () => {
            if (document.hidden) return;
            try {
                const manifest = await get_manifest();
                current_recording = !!manifest.current_entry;
                recording_start = manifest.current_entry?.start_time ?? null;

                await fetch_analysis_counts();

                system_stats = await get_system_stats();
                const sq = await get_signal_quality();
                signal_quality = sq;

                if (sq) {
                    rsrp_history = push_sample(rsrp_history, sq.serving_cell.rsrp);
                    sinr_history = push_sample(sinr_history, sq.serving_cell.sinr);
                    rsrq_history = push_sample(rsrq_history, sq.serving_cell.rsrq);
                }

                connection_ok = true;
                loaded = true;
            } catch {
                connection_ok = false;
            }
        }, 3000);

        return () => {
            clearInterval(clock_interval);
            clearInterval(data_interval);
        };
    });
</script>

<svelte:head>
    <title>Rayhunter Dashboard</title>
    <meta name="theme-color" content="#0f172a" />
    <style>
        html, body { background-color: #0f172a !important; }
    </style>
</svelte:head>

<div class="dashboard">
    <!-- Top bar -->
    <div class="top-bar">
        <div class="top-left">
            <img src="/rayhunter_orca_only.png" alt="" class="logo" />
            <span class="title">RAYHUNTER</span>
            {#if !connection_ok}
                <span class="conn-error">DISCONNECTED</span>
            {/if}
        </div>
        <div class="top-right">
            {#if current_recording}
                <div class="rec-badge">
                    <span class="rec-dot-inline"></span>
                    <span class="rec-timer">{recording_duration ? `REC ${recording_duration}` : 'REC'}</span>
                </div>
            {/if}
            <span class="clock">{clock}</span>
        </div>
    </div>

    {#if !loaded}
        <div class="loading">
            <img src="/rayhunter_orca_only.png" alt="" class="loading-icon" />
            <p>Connecting...</p>
        </div>
    {:else}
        <!-- Threat level banner -->
        <div class="threat-banner" style="border-color: {threat_color};">
            <div class="threat-indicator" class:threat-pulse={threat_level === 'HIGH'} style="background: {threat_color};"></div>
            <span class="threat-text" style="color: {threat_color};">THREAT LEVEL: {threat_level}</span>
            {#if total_rows > 0}
                <span class="packets-scanned">{total_rows.toLocaleString()} packets scanned</span>
            {/if}
        </div>

        <div class="panels">
            <!-- Left: Signal -->
            <div class="panel signal-panel">
                <h2>Signal</h2>
                {#if signal_quality}
                    <svg width="120" height="90" viewBox="0 0 120 90" class="signal-bars" xmlns="http://www.w3.org/2000/svg">
                        <title>Signal strength: {level}</title>
                        <rect x="4" y="68" width="20" height="20" rx="2" fill={bars >= 1 ? color : '#374151'} />
                        <rect x="30" y="48" width="20" height="40" rx="2" fill={bars >= 2 ? color : '#374151'} />
                        <rect x="56" y="28" width="20" height="60" rx="2" fill={bars >= 3 ? color : '#374151'} />
                        <rect x="82" y="8" width="20" height="80" rx="2" fill={bars >= 4 ? color : '#374151'} />
                    </svg>
                    <div class="signal-value" style="color: {color}">
                        {signal_quality.serving_cell.rsrp} dBm
                    </div>
                    <div class="signal-level" style="color: {color}">{level}</div>
                    <div class="signal-details">
                        <div class="detail-row">
                            <span class="detail-label">RSRQ</span>
                            <span class="detail-value">{signal_quality.serving_cell.rsrq} dB</span>
                        </div>
                        <div class="detail-row">
                            <span class="detail-label">SINR</span>
                            <span class="detail-value">{signal_quality.serving_cell.sinr} dB</span>
                        </div>
                        <div class="detail-row">
                            <span class="detail-label">RSSI</span>
                            <span class="detail-value">{signal_quality.serving_cell.rssi} dBm</span>
                        </div>
                        <div class="detail-row">
                            <span class="detail-label">Band</span>
                            <span class="detail-value">B{signal_quality.serving_cell.band} {signal_quality.serving_cell.duplex}</span>
                        </div>
                        <div class="detail-row">
                            <span class="detail-label">Cell</span>
                            <span class="detail-value">{signal_quality.serving_cell.cell_id}</span>
                        </div>
                        <div class="detail-row">
                            <span class="detail-label">PCI</span>
                            <span class="detail-value">{signal_quality.serving_cell.pci}</span>
                        </div>
                        <div class="detail-row">
                            <span class="detail-label">MCC/MNC</span>
                            <span class="detail-value">{signal_quality.serving_cell.mcc}/{signal_quality.serving_cell.mnc}</span>
                        </div>
                    </div>
                {:else}
                    <div class="no-data">No signal data</div>
                {/if}
            </div>

            <!-- Center: Threat Monitor -->
            <div class="panel threat-panel">
                <h2>Threat Monitor</h2>

                <!-- Active defenses grid -->
                <div class="defense-grid">
                    {#each ANALYZERS as analyzer}
                        {@const active = is_analyzer_active(analyzer.key)}
                        <div class="defense-item" class:active title={analyzer.desc}>
                            <div class="defense-icon" class:active>
                                <span>{analyzer.icon}</span>
                            </div>
                            <span class="defense-name">{analyzer.name}</span>
                        </div>
                    {/each}
                </div>

                <!-- Warning counts -->
                <div class="warning-grid">
                    <div class="warning-box warning-high">
                        <span class="warning-count">{warning_counts.high}</span>
                        <span class="warning-label">HIGH</span>
                    </div>
                    <div class="warning-box warning-medium">
                        <span class="warning-count">{warning_counts.medium}</span>
                        <span class="warning-label">MEDIUM</span>
                    </div>
                    <div class="warning-box warning-low">
                        <span class="warning-count">{warning_counts.low}</span>
                        <span class="warning-label">LOW</span>
                    </div>
                    <div class="warning-box warning-info">
                        <span class="warning-count">{warning_counts.info}</span>
                        <span class="warning-label">INFO</span>
                    </div>
                </div>
            </div>

            <!-- Right: System -->
            <div class="panel system-panel">
                <h2>System</h2>
                <div class="recording-status">
                    <span class="rec-dot" class:active={current_recording}></span>
                    <span class="rec-label">
                        {current_recording ? 'RECORDING' : 'NOT RECORDING'}
                    </span>
                </div>
                {#if system_stats}
                    <div class="gauge-section">
                        <div class="gauge-label">Disk</div>
                        <div class="gauge-bar">
                            <div class="gauge-fill" style="width: {disk_percent_num}%; background: {disk_color};"></div>
                        </div>
                        <div class="gauge-text">{system_stats.disk_stats.used_percent} ({system_stats.disk_stats.used_size} / {system_stats.disk_stats.total_size})</div>
                    </div>
                    <div class="gauge-section">
                        <div class="gauge-label">Memory</div>
                        <div class="detail-row">
                            <span class="detail-label">Used</span>
                            <span class="detail-value">{system_stats.memory_stats.used}</span>
                        </div>
                        <div class="detail-row">
                            <span class="detail-label">Free</span>
                            <span class="detail-value">{system_stats.memory_stats.free}</span>
                        </div>
                    </div>
                    {#if system_stats.battery_status}
                        <div class="gauge-section">
                            <div class="gauge-label">Battery</div>
                            <div class="gauge-bar">
                                <div class="gauge-fill" style="width: {system_stats.battery_status.level}%; background: {system_stats.battery_status.level > 20 ? '#22c55e' : '#ef4444'};"></div>
                            </div>
                            <div class="gauge-text">
                                {system_stats.battery_status.level}%
                                {system_stats.battery_status.is_plugged_in ? '(charging)' : ''}
                            </div>
                        </div>
                    {/if}
                    <div class="version-info">
                        v{system_stats.runtime_metadata.rayhunter_version}
                    </div>
                {:else}
                    <div class="no-data">Loading...</div>
                {/if}
            </div>
        </div>

        <!-- Charts row -->
        {#if rsrp_history.length >= 2}
            <div class="charts-row">
                <div class="chart-card">
                    <div class="chart-header">
                        <span class="chart-title" title={RSRP_TOOLTIP}>RSRP &#9432;</span>
                        <span class="chart-value" style="color: {color}">{chart_last(rsrp_history)} dBm</span>
                    </div>
                    <svg viewBox="0 0 280 80" class="chart-svg" xmlns="http://www.w3.org/2000/svg">
                        {#each rsrp_zones.rects as zone}
                            <rect x="0" y={zone.y} width="280" height={zone.h} fill={zone.color} />
                        {/each}
                        {#each rsrp_zones.boundaries as by}
                            <line x1="0" y1={by} x2="280" y2={by} class="zone-boundary" />
                        {/each}
                        {#each rsrp_zones.rects as zone}
                            <text x="276" y={zone.ly} text-anchor="end" dominant-baseline="central" class="zone-label">{zone.label}</text>
                        {/each}
                        <text x="4" y="4" dominant-baseline="hanging" class="y-axis-label">{RSRP_RANGE.max} dBm</text>
                        <text x="4" y="76" dominant-baseline="auto" class="y-axis-label">{RSRP_RANGE.min} dBm</text>
                        <polyline points={rsrp_line} class="chart-line" />
                    </svg>
                </div>
                <div class="chart-card">
                    <div class="chart-header">
                        <span class="chart-title" title={SINR_TOOLTIP}>SINR &#9432;</span>
                        <span class="chart-value" style="color: {sinr_color}">{chart_last(sinr_history)} dB</span>
                    </div>
                    <svg viewBox="0 0 280 80" class="chart-svg" xmlns="http://www.w3.org/2000/svg">
                        {#each sinr_zones.rects as zone}
                            <rect x="0" y={zone.y} width="280" height={zone.h} fill={zone.color} />
                        {/each}
                        {#each sinr_zones.boundaries as by}
                            <line x1="0" y1={by} x2="280" y2={by} class="zone-boundary" />
                        {/each}
                        {#each sinr_zones.rects as zone}
                            <text x="276" y={zone.ly} text-anchor="end" dominant-baseline="central" class="zone-label">{zone.label}</text>
                        {/each}
                        <text x="4" y="4" dominant-baseline="hanging" class="y-axis-label">{SINR_RANGE.max} dB</text>
                        <text x="4" y="76" dominant-baseline="auto" class="y-axis-label">{SINR_RANGE.min} dB</text>
                        <polyline points={sinr_line} class="chart-line" />
                    </svg>
                </div>
                <div class="chart-card">
                    <div class="chart-header">
                        <span class="chart-title" title={RSRQ_TOOLTIP}>RSRQ &#9432;</span>
                        <span class="chart-value" style="color: {rsrq_color}">{chart_last(rsrq_history)} dB</span>
                    </div>
                    <svg viewBox="0 0 280 80" class="chart-svg" xmlns="http://www.w3.org/2000/svg">
                        {#each rsrq_zones.rects as zone}
                            <rect x="0" y={zone.y} width="280" height={zone.h} fill={zone.color} />
                        {/each}
                        {#each rsrq_zones.boundaries as by}
                            <line x1="0" y1={by} x2="280" y2={by} class="zone-boundary" />
                        {/each}
                        {#each rsrq_zones.rects as zone}
                            <text x="276" y={zone.ly} text-anchor="end" dominant-baseline="central" class="zone-label">{zone.label}</text>
                        {/each}
                        <text x="4" y="4" dominant-baseline="hanging" class="y-axis-label">{RSRQ_RANGE.max} dB</text>
                        <text x="4" y="76" dominant-baseline="auto" class="y-axis-label">{RSRQ_RANGE.min} dB</text>
                        <polyline points={rsrq_line} class="chart-line" />
                    </svg>
                </div>
            </div>
        {/if}

        <!-- Bottom: Neighbour cells -->
        {#if signal_quality && signal_quality.neighbour_cells.length > 0}
            <div class="neighbour-panel">
                <h2>Neighbour Cells</h2>
                <div class="neighbour-table">
                    <table>
                        <thead>
                            <tr>
                                <th>Type</th>
                                <th>PCI</th>
                                <th>EARFCN</th>
                                <th>RSRP</th>
                                <th>RSRQ</th>
                                <th>RSSI</th>
                            </tr>
                        </thead>
                        <tbody>
                            {#each signal_quality.neighbour_cells as cell}
                                <tr>
                                    <td>{cell.type}</td>
                                    <td>{cell.pci}</td>
                                    <td>{cell.earfcn}</td>
                                    <td style="color: {getSignalColor(cell.rsrp)}">{cell.rsrp}</td>
                                    <td>{cell.rsrq}</td>
                                    <td>{cell.rssi}</td>
                                </tr>
                            {/each}
                        </tbody>
                    </table>
                </div>
            </div>
        {/if}
    {/if}

    <div class="back-link">
        <a href="/">Back to main UI</a>
    </div>
</div>

<style>
    .dashboard {
        min-height: 100vh;
        background: #0f172a;
        color: #e2e8f0;
        font-family: system-ui, -apple-system, sans-serif;
        display: flex;
        flex-direction: column;
        padding: 0;
        margin: 0;
    }

    /* Top bar */
    .top-bar {
        display: flex;
        justify-content: space-between;
        align-items: center;
        padding: 0.75rem 2rem;
        background: #1e293b;
        border-bottom: 1px solid #334155;
    }
    .top-left {
        display: flex;
        align-items: center;
        gap: 0.75rem;
    }
    .logo { height: 2rem; }
    .title {
        font-size: 1.25rem;
        font-weight: 700;
        letter-spacing: 0.15em;
        color: #38bdf8;
    }
    .conn-error {
        color: #ef4444;
        font-size: 0.75rem;
        font-weight: 600;
        padding: 0.125rem 0.5rem;
        background: rgba(239, 68, 68, 0.15);
        border-radius: 0.25rem;
        animation: blink 1s infinite;
    }
    .top-right {
        display: flex;
        align-items: center;
        gap: 1.5rem;
        flex-shrink: 1;
        min-width: 0;
    }
    .rec-badge {
        display: flex;
        align-items: center;
        gap: 0.5rem;
        padding: 0.25rem 0.75rem;
        background: rgba(34, 197, 94, 0.12);
        border: 1px solid rgba(34, 197, 94, 0.3);
        border-radius: 0.375rem;
    }
    .rec-dot-inline {
        width: 8px;
        height: 8px;
        border-radius: 50%;
        background: #22c55e;
        animation: pulse-dot 2s infinite;
    }
    .rec-timer {
        font-size: 0.875rem;
        font-weight: 600;
        font-variant-numeric: tabular-nums;
        color: #22c55e;
    }
    .clock {
        font-size: 1.5rem;
        font-weight: 300;
        font-variant-numeric: tabular-nums;
    }

    /* Threat banner */
    .threat-banner {
        display: flex;
        align-items: center;
        gap: 0.75rem;
        padding: 0.5rem 2rem;
        background: #0f172a;
        border-bottom: 2px solid;
    }
    .threat-indicator {
        width: 12px;
        height: 12px;
        border-radius: 50%;
        flex-shrink: 0;
    }
    .threat-pulse {
        animation: pulse-threat 1.5s infinite;
    }
    .threat-text {
        font-size: 0.8125rem;
        font-weight: 700;
        letter-spacing: 0.15em;
    }
    .packets-scanned {
        margin-left: auto;
        font-size: 0.75rem;
        color: #64748b;
        font-variant-numeric: tabular-nums;
    }

    /* Loading */
    .loading {
        flex: 1;
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        gap: 1rem;
    }
    .loading-icon {
        height: 6rem;
        animation: spin 2s linear infinite;
    }

    /* Animations */
    @keyframes spin {
        from { transform: rotate(0deg); }
        to { transform: rotate(360deg); }
    }
    @keyframes blink {
        0%, 100% { opacity: 1; }
        50% { opacity: 0.5; }
    }
    @keyframes pulse-dot {
        0%, 100% { box-shadow: 0 0 0 0 rgba(34, 197, 94, 0.7); }
        50% { box-shadow: 0 0 0 8px rgba(34, 197, 94, 0); }
    }
    @keyframes pulse-threat {
        0%, 100% { box-shadow: 0 0 0 0 rgba(239, 68, 68, 0.7); }
        50% { box-shadow: 0 0 0 10px rgba(239, 68, 68, 0); }
    }

    /* Panels */
    .panels {
        display: grid;
        grid-template-columns: 1fr 1.3fr 1fr;
        gap: 1rem;
        padding: 1rem 2rem;
    }
    .panel {
        background: #1e293b;
        border: 1px solid #334155;
        border-radius: 0.5rem;
        padding: 1.25rem;
        display: flex;
        flex-direction: column;
    }
    .panel h2 {
        font-size: 0.875rem;
        text-transform: uppercase;
        letter-spacing: 0.1em;
        color: #64748b;
        margin: 0 0 1rem 0;
        padding-bottom: 0.5rem;
        border-bottom: 1px solid #334155;
    }

    /* Signal panel */
    .signal-bars { margin: 0 auto 0.75rem; }
    .signal-value {
        text-align: center;
        font-size: 2rem;
        font-weight: 700;
        font-variant-numeric: tabular-nums;
    }
    .signal-level {
        text-align: center;
        font-size: 1rem;
        font-weight: 600;
        margin-bottom: 1rem;
    }
    .signal-details {
        display: flex;
        flex-direction: column;
        gap: 0.375rem;
    }

    /* Shared detail rows */
    .detail-row {
        display: flex;
        justify-content: space-between;
        padding: 0.25rem 0;
        border-bottom: 1px solid #1e293b;
    }
    .detail-label {
        color: #94a3b8;
        font-size: 0.8125rem;
    }
    .detail-value {
        font-variant-numeric: tabular-nums;
        font-size: 0.8125rem;
    }

    /* Threat monitor - defense grid */
    .defense-grid {
        display: grid;
        grid-template-columns: repeat(4, 1fr);
        gap: 0.5rem;
        margin-bottom: 1rem;
    }
    .defense-item {
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: 0.25rem;
        padding: 0.375rem;
        opacity: 0.3;
    }
    .defense-item.active {
        opacity: 1;
    }
    .defense-icon {
        width: 32px;
        height: 32px;
        border-radius: 50%;
        display: flex;
        align-items: center;
        justify-content: center;
        background: #374151;
        border: 2px solid #4b5563;
        font-size: 0.625rem;
        font-weight: 700;
        color: #6b7280;
        letter-spacing: 0.02em;
    }
    .defense-icon.active {
        background: rgba(34, 197, 94, 0.15);
        border-color: #22c55e;
        color: #22c55e;
    }
    .defense-name {
        font-size: 0.5625rem;
        text-align: center;
        color: #94a3b8;
        line-height: 1.2;
    }

    /* Warning grid */
    .warning-grid {
        display: grid;
        grid-template-columns: 1fr 1fr 1fr 1fr;
        gap: 0.5rem;
    }
    .warning-box {
        display: flex;
        flex-direction: column;
        align-items: center;
        padding: 0.5rem;
        border-radius: 0.375rem;
        border: 1px solid #334155;
    }
    .warning-count {
        font-size: 1.5rem;
        font-weight: 700;
        font-variant-numeric: tabular-nums;
        line-height: 1;
    }
    .warning-label {
        font-size: 0.5625rem;
        letter-spacing: 0.1em;
        margin-top: 0.125rem;
        opacity: 0.8;
    }
    .warning-high { background: rgba(239, 68, 68, 0.15); }
    .warning-high .warning-count { color: #ef4444; }
    .warning-medium { background: rgba(249, 115, 22, 0.15); }
    .warning-medium .warning-count { color: #f97316; }
    .warning-low { background: rgba(234, 179, 8, 0.15); }
    .warning-low .warning-count { color: #eab308; }
    .warning-info { background: rgba(59, 130, 246, 0.15); }
    .warning-info .warning-count { color: #3b82f6; }

    /* System panel */
    .recording-status {
        display: flex;
        align-items: center;
        gap: 0.75rem;
        margin-bottom: 1rem;
    }
    .rec-dot {
        width: 12px;
        height: 12px;
        border-radius: 50%;
        background: #6b7280;
        flex-shrink: 0;
    }
    .rec-dot.active {
        background: #22c55e;
        animation: pulse-dot 2s infinite;
    }
    .rec-label {
        font-weight: 600;
        font-size: 0.875rem;
        letter-spacing: 0.05em;
    }
    .gauge-section { margin-bottom: 1rem; }
    .gauge-label {
        font-size: 0.8125rem;
        color: #94a3b8;
        margin-bottom: 0.5rem;
    }
    .gauge-bar {
        height: 0.5rem;
        background: #374151;
        border-radius: 0.25rem;
        overflow: hidden;
        margin-bottom: 0.25rem;
    }
    .gauge-fill {
        height: 100%;
        border-radius: 0.25rem;
        transition: width 0.5s ease;
    }
    .gauge-text {
        font-size: 0.75rem;
        color: #94a3b8;
    }
    .version-info {
        margin-top: auto;
        color: #475569;
        font-size: 0.75rem;
        text-align: center;
    }
    .no-data {
        color: #475569;
        text-align: center;
        padding: 2rem;
    }

    /* Charts */
    .charts-row {
        display: grid;
        grid-template-columns: 1fr 1fr 1fr;
        gap: 1rem;
        padding: 0 2rem 1rem;
    }
    .chart-card {
        background: #1e293b;
        border: 1px solid #334155;
        border-radius: 0.5rem;
        padding: 0.75rem 1rem;
    }
    .chart-header {
        display: flex;
        justify-content: space-between;
        align-items: baseline;
        margin-bottom: 0.375rem;
    }
    .chart-title {
        font-size: 0.75rem;
        text-transform: uppercase;
        letter-spacing: 0.1em;
        color: #64748b;
        cursor: help;
    }
    .chart-value {
        font-size: 0.875rem;
        font-weight: 600;
        font-variant-numeric: tabular-nums;
    }
    .chart-svg {
        width: 100%;
        display: block;
    }
    .chart-svg :global(.zone-boundary) {
        stroke: rgba(255, 255, 255, 0.08);
        stroke-width: 0.5;
        stroke-dasharray: 4 3;
    }
    .chart-svg :global(.zone-label) {
        font-size: 6px;
        fill: rgba(255, 255, 255, 0.25);
        font-weight: 500;
        font-family: system-ui, sans-serif;
    }
    .chart-svg :global(.y-axis-label) {
        font-size: 5.5px;
        fill: rgba(255, 255, 255, 0.35);
        font-family: system-ui, sans-serif;
    }
    .chart-line {
        fill: none;
        stroke: white;
        stroke-width: 0.8;
        stroke-linejoin: round;
        stroke-linecap: round;
        filter: drop-shadow(0 0 2px rgba(255, 255, 255, 0.6)) drop-shadow(0 0 6px rgba(255, 255, 255, 0.3));
    }

    /* Neighbour cells panel */
    .neighbour-panel {
        background: #1e293b;
        border: 1px solid #334155;
        border-radius: 0.5rem;
        padding: 1.25rem;
        margin: 0 2rem 1rem;
    }
    .neighbour-panel h2 {
        font-size: 0.875rem;
        text-transform: uppercase;
        letter-spacing: 0.1em;
        color: #64748b;
        margin: 0 0 1rem 0;
        padding-bottom: 0.5rem;
        border-bottom: 1px solid #334155;
    }
    .neighbour-table { overflow-x: auto; }
    .neighbour-table table {
        width: 100%;
        border-collapse: collapse;
        font-size: 0.8125rem;
    }
    .neighbour-table th {
        text-align: left;
        padding: 0.25rem 0.75rem;
        color: #64748b;
        font-weight: 500;
        border-bottom: 1px solid #334155;
    }
    .neighbour-table td {
        padding: 0.25rem 0.75rem;
        font-variant-numeric: tabular-nums;
        border-bottom: 1px solid #1e293b;
    }

    /* Back link */
    .back-link {
        text-align: center;
        padding: 0.5rem;
        background: #1e293b;
    }
    .back-link a {
        color: #38bdf8;
        font-size: 0.75rem;
        text-decoration: none;
    }
    .back-link a:hover { text-decoration: underline; }

    /* Responsive */
    @media (max-width: 768px) {
        .panels { grid-template-columns: 1fr; }
        .charts-row { grid-template-columns: 1fr; }
        .dashboard { margin: 0; }
        .defense-grid { grid-template-columns: repeat(4, 1fr); }
        .warning-grid { grid-template-columns: 1fr 1fr; }
        .top-bar { padding: 0.5rem 1rem; flex-wrap: wrap; gap: 0.5rem; }
        .top-left { gap: 0.5rem; }
        .top-right { gap: 0.75rem; }
        .title { font-size: 1rem; }
        .clock { font-size: 1rem; }
        .rec-badge { padding: 0.2rem 0.5rem; }
        .rec-timer { font-size: 0.75rem; }
        .neighbour-panel { margin: 0 1rem 1rem; }
        .panels { padding: 1rem; }
        .charts-row { padding: 0 1rem 1rem; }
        .threat-banner { padding: 0.5rem 1rem; }
    }
</style>
