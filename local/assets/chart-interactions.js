'use strict';

(function initialiseTimeSliceInteractions(global) {
  const chartStates = new WeakMap();
  const datasetCaches = new WeakMap();
  const ChartConstructor = global.Chart;

  function stateFor(chart) {
    let state = chartStates.get(chart);
    if (!state) {
      state = { timestamp: null, pixel: null };
      chartStates.set(chart, state);
    }
    return state;
  }

  function clearSelection(chart) {
    const state = stateFor(chart);
    state.timestamp = null;
    state.pixel = null;
  }

  function finitePoint(point) {
    if (!point || typeof point !== 'object') return null;
    if (point.x === null || point.x === undefined || point.x === '' || typeof point.x === 'boolean') return null;
    if (point.y === null || point.y === undefined || point.y === '' || typeof point.y === 'boolean') return null;
    const x = Number(point.x);
    const y = Number(point.y);
    return Number.isFinite(x) && Number.isFinite(y) ? { x, y } : null;
  }

  function searchablePoints(chart, dataset) {
    const data = Array.isArray(dataset?.data) ? dataset.data : [];
    const cached = datasetCaches.get(dataset);
    const version = stateFor(chart).cacheVersion || 0;
    if (cached && cached.data === data && cached.length === data.length && cached.version === version) return cached.points;
    const points = [];
    for (let index = 0; index < data.length; index += 1) {
      const point = finitePoint(data[index]);
      if (point) points.push({ x: point.x, index });
    }
    points.sort((left, right) => left.x - right.x || left.index - right.index);
    datasetCaches.set(dataset, { data, length: data.length, version, points });
    return points;
  }

  function lowerBound(points, timestamp) {
    let low = 0;
    let high = points.length;
    while (low < high) {
      const middle = (low + high) >> 1;
      if (points[middle].x < timestamp) low = middle + 1;
      else high = middle;
    }
    return low;
  }

  function closestPoint(points, timestamp) {
    if (!points.length) return null;
    const rightIndex = lowerBound(points, timestamp);
    const right = rightIndex < points.length ? points[rightIndex] : null;
    const left = rightIndex > 0 ? points[rightIndex - 1] : null;
    if (!left) return right;
    if (!right) return left;
    const leftDistance = Math.abs(timestamp - left.x);
    const rightDistance = Math.abs(right.x - timestamp);
    return leftDistance <= rightDistance ? left : right;
  }

  function pointAt(points, timestamp) {
    const index = lowerBound(points, timestamp);
    return index < points.length && points[index].x === timestamp ? points[index] : null;
  }

  function eligibleDataset(chart, datasetIndex) {
    const dataset = chart.data?.datasets?.[datasetIndex];
    return Boolean(dataset)
      && dataset.timeSliceExcluded !== true
      && chart.isDatasetVisible(datasetIndex);
  }

  function timeSliceMode(chart, event) {
    const xScale = chart.scales?.x;
    const eventX = Number(event?.x);
    if (!xScale || !Number.isFinite(eventX)) {
      clearSelection(chart);
      return [];
    }
    const requestedTimestamp = Number(xScale.getValueForPixel(eventX));
    if (!Number.isFinite(requestedTimestamp)) {
      clearSelection(chart);
      return [];
    }

    let selectedTimestamp = null;
    let selectedDistance = Number.POSITIVE_INFINITY;
    const datasets = chart.data?.datasets || [];
    for (let datasetIndex = 0; datasetIndex < datasets.length; datasetIndex += 1) {
      if (!eligibleDataset(chart, datasetIndex)) continue;
      const candidate = closestPoint(searchablePoints(chart, datasets[datasetIndex]), requestedTimestamp);
      if (!candidate) continue;
      const distance = Math.abs(candidate.x - requestedTimestamp);
      if (distance < selectedDistance || (distance === selectedDistance && (selectedTimestamp === null || candidate.x < selectedTimestamp))) {
        selectedTimestamp = candidate.x;
        selectedDistance = distance;
      }
    }

    if (selectedTimestamp === null) {
      clearSelection(chart);
      return [];
    }

    const active = [];
    for (let datasetIndex = 0; datasetIndex < datasets.length; datasetIndex += 1) {
      if (!eligibleDataset(chart, datasetIndex)) continue;
      const match = pointAt(searchablePoints(chart, datasets[datasetIndex]), selectedTimestamp);
      const element = match ? chart.getDatasetMeta(datasetIndex)?.data?.[match.index] : null;
      if (match && element && !element.skip) active.push({ element, datasetIndex, index: match.index });
    }
    const state = stateFor(chart);
    state.timestamp = selectedTimestamp;
    state.pixel = Number(xScale.getPixelForValue(selectedTimestamp));
    return active;
  }

  const cursorPlugin = {
    id: 'timeSliceCursor',
    defaults: {
      enabled: true,
      color: 'rgba(230, 237, 243, 0.55)',
      width: 1,
      dash: [4, 4],
    },
    beforeUpdate(chart) {
      const state = stateFor(chart);
      state.cacheVersion = (state.cacheVersion || 0) + 1;
      clearSelection(chart);
    },
    afterUpdate(chart) {
      chart.setActiveElements?.([]);
      chart.tooltip?.setActiveElements?.([], { x: 0, y: 0 });
    },
    afterEvent(chart, args) {
      if (args.event?.type !== 'mouseout') return;
      clearSelection(chart);
      args.changed = true;
    },
    afterDatasetsDraw(chart, _args, options) {
      const state = chartStates.get(chart);
      const area = chart.chartArea;
      if (!options.enabled || !state || !Number.isFinite(state.pixel) || !area) return;
      const active = chart.tooltip?.getActiveElements?.() || [];
      if (!active.length || state.pixel < area.left || state.pixel > area.right) return;
      const context = chart.ctx;
      context.save();
      context.beginPath();
      context.moveTo(state.pixel, area.top);
      context.lineTo(state.pixel, area.bottom);
      context.lineWidth = options.width;
      context.strokeStyle = options.color;
      context.setLineDash(options.dash || []);
      context.stroke();
      context.restore();
    },
    afterDestroy(chart) {
      chartStates.delete(chart);
    },
  };

  let registered = false;
  function register() {
    if (registered) return true;
    if (typeof ChartConstructor !== 'function') return false;
    ChartConstructor.Interaction.modes.timeSlice = timeSliceMode;
    ChartConstructor.register(cursorPlugin);
    registered = true;
    return true;
  }

  function enhanceOptions(options = {}, config = {}) {
    if (!register()) return options;
    const tooltip = options.plugins?.tooltip || {};
    const callbacks = tooltip.callbacks || {};
    const previousFilter = tooltip.filter;
    options.interaction = { ...(options.interaction || {}), mode: 'timeSlice', axis: 'x', intersect: false };
    options.plugins = {
      ...(options.plugins || {}),
      timeSliceCursor: { enabled: true, ...(options.plugins?.timeSliceCursor || {}) },
      tooltip: {
        ...tooltip,
        mode: 'timeSlice',
        axis: 'x',
        intersect: false,
        filter(item, index, items, data) {
          const value = item.parsed?.y;
          if (item.dataset?.timeSliceExcluded === true
            || value === null || value === undefined || value === '' || typeof value === 'boolean'
            || !Number.isFinite(Number(value))) return false;
          return typeof previousFilter === 'function' ? previousFilter(item, index, items, data) : true;
        },
        callbacks: {
          ...callbacks,
          title(items) {
            if (!items.length) return '';
            return typeof config.formatTitle === 'function'
              ? config.formatTitle(items[0].parsed.x, items)
              : callbacks.title?.(items) || String(items[0].parsed.x);
          },
          label(context) {
            if (typeof config.formatValue !== 'function') return callbacks.label?.(context);
            const label = context.dataset?.label ? `${context.dataset.label}: ` : '';
            return `${label}${config.formatValue(context.parsed.y, context.dataset?.valueKind, context)}`;
          },
        },
      },
    };
    return options;
  }

  global.CodexChartInteractions = Object.freeze({ enhanceOptions });
  register();
})(typeof window === 'object' ? window : globalThis);
