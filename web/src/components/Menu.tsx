import {
  Fragment,
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type KeyboardEvent,
} from "react";

export type MenuItem = {
  label: string;
  onSelect: () => void;
  danger?: boolean;
  disabled?: boolean;
  separated?: boolean;
};

const ENABLED_ITEM = '[role="menuitem"]:not(:disabled)';

export function Menu({
  label,
  x,
  y,
  items,
  onClose,
}: {
  label: string;
  x: number;
  y: number;
  items: MenuItem[];
  onClose: (restoreFocus: boolean) => void;
}) {
  const menu = useRef<HTMLDivElement>(null);
  const close = useRef(onClose);
  close.current = onClose;
  const [position, setPosition] = useState({ left: x, top: y });
  const signature = items.map((item) => item.label).join("\n");
  useLayoutEffect(() => {
    const box = menu.current?.getBoundingClientRect();
    if (!box) return;
    setPosition({
      left: Math.max(8, Math.min(x, window.innerWidth - box.width - 8)),
      top:
        y + box.height > window.innerHeight - 8
          ? Math.max(8, y - box.height)
          : y,
    });
    menu.current?.querySelector<HTMLButtonElement>(ENABLED_ITEM)?.focus();
  }, [x, y, signature]);
  useEffect(() => {
    const outside = (event: Event) => {
      const target = event.target;
      if (
        target instanceof Element &&
        (menu.current?.contains(target) ||
          target.closest('[aria-haspopup="menu"][aria-expanded="true"]'))
      )
        return;
      close.current(false);
    };
    const dismiss = () => close.current(false);
    document.addEventListener("mousedown", outside, true);
    document.addEventListener("scroll", outside, true);
    window.addEventListener("blur", dismiss);
    window.addEventListener("resize", dismiss);
    return () => {
      document.removeEventListener("mousedown", outside, true);
      document.removeEventListener("scroll", outside, true);
      window.removeEventListener("blur", dismiss);
      window.removeEventListener("resize", dismiss);
    };
  }, []);
  const keyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    const enabled = [
      ...(menu.current?.querySelectorAll<HTMLButtonElement>(ENABLED_ITEM) ||
        []),
    ];
    const index = enabled.indexOf(document.activeElement as HTMLButtonElement);
    const move = { ArrowDown: 1, ArrowUp: -1 }[event.key];
    if (move) {
      event.preventDefault();
      enabled[(index + move + enabled.length) % enabled.length]?.focus();
    } else if (event.key === "Home" || event.key === "End") {
      event.preventDefault();
      enabled[event.key === "Home" ? 0 : enabled.length - 1]?.focus();
    } else if (event.key === "Escape" || event.key === "Tab") {
      event.preventDefault();
      event.stopPropagation();
      close.current(true);
    }
  };
  return (
    <div
      ref={menu}
      className="menu"
      role="menu"
      aria-label={label}
      style={position}
      onKeyDown={keyDown}
    >
      {items.map((item) => (
        <Fragment key={item.label}>
          {item.separated && <div className="menu-separator" role="separator" />}
          <button
            role="menuitem"
            className={item.danger ? "menu-danger" : ""}
            disabled={item.disabled}
            onClick={item.onSelect}
          >
            {item.label}
          </button>
        </Fragment>
      ))}
    </div>
  );
}
