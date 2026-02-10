<script lang="ts">
    import type { SignalQuality } from '$lib/signalQuality';
    import { getSignalBars, getSignalColor, getSignalLevel } from '$lib/signalQuality';

    let {
        signal,
    }: {
        signal: SignalQuality | null;
    } = $props();

    const table_cell_classes = 'border p-1 lg:p-2';

    let bars = $derived(signal ? getSignalBars(signal.serving_cell.rsrp) : 0);
    let color = $derived(signal ? getSignalColor(signal.serving_cell.rsrp) : '#6b7280');
    let level = $derived(signal ? getSignalLevel(signal.serving_cell.rsrp) : 'No Signal');
</script>

<div
    class="flex-1 drop-shadow p-4 flex flex-col gap-2 border rounded-md bg-gray-100 border-gray-100"
>
    <p class="text-xl mb-2">Signal Quality</p>
    {#if signal}
        <div class="flex flex-row items-center gap-3 mb-2">
            <!-- Signal bars SVG -->
            <svg width="48" height="36" viewBox="0 0 48 36" role="img" xmlns="http://www.w3.org/2000/svg">
                <title>Signal strength: {level}</title>
                <rect x="2" y="28" width="8" height="8" rx="1" fill={bars >= 1 ? color : '#d1d5db'} />
                <rect x="14" y="20" width="8" height="16" rx="1" fill={bars >= 2 ? color : '#d1d5db'} />
                <rect x="26" y="12" width="8" height="24" rx="1" fill={bars >= 3 ? color : '#d1d5db'} />
                <rect x="38" y="4" width="8" height="32" rx="1" fill={bars >= 4 ? color : '#d1d5db'} />
            </svg>
            <div class="flex flex-col">
                <span class="text-lg font-bold" style="color: {color}">{level}</span>
                <span class="text-sm text-gray-600">{signal.serving_cell.rsrp} dBm RSRP</span>
            </div>
        </div>
        <table class="table-auto border">
            <tbody>
                <tr class="border">
                    <th class={table_cell_classes}>RSRP</th>
                    <td class={table_cell_classes}>{signal.serving_cell.rsrp} dBm</td>
                </tr>
                <tr class="border">
                    <th class={table_cell_classes}>RSRQ</th>
                    <td class={table_cell_classes}>{signal.serving_cell.rsrq} dB</td>
                </tr>
                <tr class="border">
                    <th class={table_cell_classes}>SINR</th>
                    <td class={table_cell_classes}>{signal.serving_cell.sinr} dB</td>
                </tr>
                <tr class="border">
                    <th class={table_cell_classes}>RSSI</th>
                    <td class={table_cell_classes}>{signal.serving_cell.rssi} dBm</td>
                </tr>
                <tr class="border">
                    <th class={table_cell_classes}>Band</th>
                    <td class={table_cell_classes}>B{signal.serving_cell.band} ({signal.serving_cell.tech} {signal.serving_cell.duplex})</td>
                </tr>
                <tr class="border">
                    <th class={table_cell_classes}>Cell ID</th>
                    <td class={table_cell_classes}>{signal.serving_cell.cell_id}</td>
                </tr>
                <tr class="border">
                    <th class={table_cell_classes}>PCI</th>
                    <td class={table_cell_classes}>{signal.serving_cell.pci}</td>
                </tr>
                <tr class="border">
                    <th class={table_cell_classes}>EARFCN</th>
                    <td class={table_cell_classes}>{signal.serving_cell.earfcn}</td>
                </tr>
                <tr class="border">
                    <th class={table_cell_classes}>Network</th>
                    <td class={table_cell_classes}>{signal.serving_cell.mcc}/{signal.serving_cell.mnc}</td>
                </tr>
            </tbody>
        </table>
        {#if signal.neighbour_cells.length > 0}
            <details class="mt-2">
                <summary class="cursor-pointer text-sm text-gray-600">
                    {signal.neighbour_cells.length} neighbour cell{signal.neighbour_cells.length !== 1 ? 's' : ''}
                </summary>
                <table class="table-auto border mt-1 text-sm w-full">
                    <thead>
                        <tr class="border bg-gray-200">
                            <th class={table_cell_classes}>Type</th>
                            <th class={table_cell_classes}>PCI</th>
                            <th class={table_cell_classes}>EARFCN</th>
                            <th class={table_cell_classes}>RSRP</th>
                            <th class={table_cell_classes}>RSRQ</th>
                        </tr>
                    </thead>
                    <tbody>
                        {#each signal.neighbour_cells as cell}
                            <tr class="border">
                                <td class={table_cell_classes}>{cell.type}</td>
                                <td class={table_cell_classes}>{cell.pci}</td>
                                <td class={table_cell_classes}>{cell.earfcn}</td>
                                <td class={table_cell_classes}>{cell.rsrp}</td>
                                <td class={table_cell_classes}>{cell.rsrq}</td>
                            </tr>
                        {/each}
                    </tbody>
                </table>
            </details>
        {/if}
    {:else}
        <p class="text-gray-500 text-sm">Signal data not available. The signal monitoring script may not be running on the router.</p>
    {/if}
</div>
