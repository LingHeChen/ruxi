import "@testing-library/jest-dom/vitest";
Object.defineProperty(window, "matchMedia", {
  value: () => ({
    matches: false,
    addListener() {},
    removeListener() {},
    addEventListener() {},
    removeEventListener() {},
    dispatchEvent() {},
  }),
});
class TestResizeObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
}
Object.defineProperty(globalThis, "ResizeObserver", {
  value: TestResizeObserver,
});
const getStyle = window.getComputedStyle;
window.getComputedStyle = (element) => getStyle(element);
