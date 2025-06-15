import React from 'react';

interface ButtonProps {
    children: React.ReactNode;
    onClick?: () => void;
    className?: string;
}

const Button = ({ children, onClick, className }: ButtonProps) => (
    <button
        onClick={onClick}
        className={`px-4 py-2 rounded-md font-medium transition-colors ${
            className || ''
        } dark:bg-gray-800 dark:text-white bg-gray-200 text-black hover:bg-gray-300 dark:hover:bg-gray-700`}
    >
        {children}
    </button>
);

export default Button;