// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

/* ==================== UNISWAP V2 ==================== */
interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}
interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
}

/* ===================== AYAZ TOKEN ===================== */
contract AyazToken is ERC20, ERC20Burnable, Ownable, Pausable {
    using Address for address payable;

    /* ---------- TOKEN INFO ---------- */
    string private constant TOKEN_NAME   = "Ayaz";
    string private constant TOKEN_SYMBOL = "A";
    uint8  private constant TOKEN_DECIMALS = 6;
    uint256 private constant INITIAL_SUPPLY = 950_000_000_000 * 10**6;

    /* ---------- ITALY COMPLIANCE ---------- */
    string public constant COUNTRY      = "Italy";
    string public constant ISSUER_VAT   = "IT12345678901";
    address public complianceOfficer;
    bool    public compliancePaused = false;

    /* ---------- TAX & WALLETS ---------- */
    uint256 public buyTax  = 500;
    uint256 public sellTax = 500;
    address public marketingWallet;
    address public liquidityWallet;
    address public taxAuthorityWallet;

    /* ---------- UNISWAP ---------- */
    IUniswapV2Router02 public immutable uniswapV2Router;
    address            public immutable uniswapV2Pair;
    bool private inSwap = false;

    /* ---------- BLACKLIST ---------- */
    mapping(address => bool) public isBlacklisted;

    /* ---------- IPFS CID ---------- */
    string public constant IPFS_METADATA_CID =
        "bafkreif4qqyqmeeuhkib53mvv2v6lqxg5a2uaq5cjiv5r3ehs2boy264ka";

    /* ---------- EVENTS ---------- */
    event TaxCollected(address indexed from, uint256 amount, string taxType);
    event ComplianceLog(address indexed from, address indexed to, uint256 amount, string action);
    event CompliancePause(bool paused);
    event ComplianceOfficerChanged(address newOfficer);

    /* ---------- MODIFIERS ---------- */
    modifier whenNotCompliancePaused() {
        require(!compliancePaused, "Compliance pause active");
        _;
    }
    modifier onlyComplianceOfficer() {
        require(msg.sender == complianceOfficer || msg.sender == owner(), "Not compliance officer");
        _;
    }
    modifier lockTheSwap {
        inSwap = true;
        _;
        inSwap = false;
    }

    /* ---------- CONSTRUCTOR ---------- */
    constructor(
        address _marketingWallet,
        address _liquidityWallet,
        address _taxAuthorityWallet,
        address _complianceOfficer
    ) ERC20(TOKEN_NAME, TOKEN_SYMBOL) Ownable(msg.sender) {
        require(_marketingWallet   != address(0), "Marketing zero");
        require(_liquidityWallet   != address(0), "Liquidity zero");
        require(_complianceOfficer != address(0), "Compliance officer zero");

        marketingWallet     = _marketingWallet;
        liquidityWallet     = _liquidityWallet;
        taxAuthorityWallet  = _taxAuthorityWallet;
        complianceOfficer   = _complianceOfficer;

        _mint(msg.sender, INITIAL_SUPPLY);

        IUniswapV2Router02 _router = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
        uniswapV2Pair = IUniswapV2Factory(_router.factory())
            .createPair(address(this), _router.WETH());
        uniswapV2Router = _router;
    }

    /* ---------- ERC‑20 OVERRIDES ---------- */
    function name()    public pure override returns (string memory) { return TOKEN_NAME; }
    function symbol()  public pure override returns (string memory) { return TOKEN_SYMBOL; }
    function decimals()public pure override returns (uint8)        { return TOKEN_DECIMALS; }

    /* ---------- TRANSFER OVERRIDE (Pausable + Compliance) ---------- */
    function transfer(address to, uint256 amount) public override whenNotPaused whenNotCompliancePaused returns (bool) {
        _customTransfer(_msgSender(), to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override whenNotPaused whenNotCompliancePaused returns (bool) {
        _customTransfer(from, to, amount);
        uint256 currentAllowance = allowance(from, _msgSender());
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _approve(from, _msgSender(), currentAllowance - amount);
        return true;
    }

    /* ---------- INTERNAL TRANSFER WITH TAX & LOGIC ---------- */
    function _customTransfer(address from, address to, uint256 amount) internal {
        require(!isBlacklisted[from], "Sender blacklisted");
        require(!isBlacklisted[to],   "Recipient blacklisted");

        if (amount == 0) {
            emit ComplianceLog(from, to, 0, "zero");
            super._transfer(from, to, 0);
            return;
        }

        // Auto-liquidity
        if (!inSwap && to == uniswapV2Pair && balanceOf(address(this)) > 0) {
            swapAndLiquify(balanceOf(address(this)));
        }

        // Tax
        uint256 taxAmount = 0;
        string memory taxType = "";
        if (from != owner() && to != owner()) {
            if (from == uniswapV2Pair) {
                taxAmount = amount * buyTax / 10_000;
                taxType = "buy";
            } else if (to == uniswapV2Pair) {
                taxAmount = amount * sellTax / 10_000;
                taxType = "sell";
            }
        }

        uint256 sendAmount = amount - taxAmount;
        if (taxAmount > 0) {
            super._transfer(from, address(this), taxAmount);
            emit TaxCollected(from, taxAmount, taxType);
        }

        super._transfer(from, to, sendAmount);
        emit ComplianceLog(from, to, sendAmount, "transfer");
    }

    /* ---------- SWAP & LIQUIFY ---------- */
    function swapAndLiquify(uint256 contractTokenBalance) private lockTheSwap {
        uint256 half = contractTokenBalance / 2;
        uint256 initBal = address(this).balance;

        swapTokensForEth(half);
        uint256 ethReceived = address(this).balance - initBal;

        addLiquidity(half, ethReceived);
    }

    function swapTokensForEth(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount, 0, path, address(this), block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this), tokenAmount, 0, 0, owner(), block.timestamp
        );
    }

    /* ---------- COMPLIANCE ---------- */
    function setCompliancePause(bool _paused) external onlyComplianceOfficer {
        compliancePaused = _paused;
        emit CompliancePause(_paused);
    }

    function updateComplianceOfficer(address _new) external onlyOwner {
        require(_new != address(0), "Zero address");
        complianceOfficer = _new;
        emit ComplianceOfficerChanged(_new);
    }

    function addToBlacklist(address _user)   external onlyComplianceOfficer { isBlacklisted[_user] = true; }
    function removeFromBlacklist(address _user) external onlyComplianceOfficer { isBlacklisted[_user] = false; }

    /* ---------- TAX SETTINGS ---------- */
    function setTax(uint256 _buyTax, uint256 _sellTax) external onlyOwner {
        require(_buyTax <= 1000 && _sellTax <= 1000, "Max 10%");
        buyTax  = _buyTax;
        sellTax = _sellTax;
    }

    function setWallets(
        address _marketing,
        address _liquidity,
        address _taxAuthority
    ) external onlyOwner {
        marketingWallet    = _marketing;
        liquidityWallet    = _liquidity;
        taxAuthorityWallet = _taxAuthority;
    }

    /* ---------- ADMIN ---------- */
    function issue(uint256 _amount) external onlyOwner { _mint(owner(), _amount); }
    function redeem(uint256 _amount) external onlyOwner { _burn(owner(), _amount); }

    /* ---------- PUBLIC SWAP ---------- */
    function swapETHForTokens(uint256 _minOut) external payable {
        address[] memory path = new address[](2);
        path[0] = uniswapV2Router.WETH();
        path[1] = address(this);
        uniswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{
            value: msg.value
        }(_minOut, path, msg.sender, block.timestamp);
    }

    receive() external payable {}
}
