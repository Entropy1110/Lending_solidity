# testWithdrawYieldSucceeds
# vm.roll(block.number + (86400 * 500 / 12));
# vm.prank(user3);
# assertTrue(lending.getAccruedSupplyAmount(address(usdc)) / 1e18 == 30001605);
#
# 위 테스트 케이스로 블록 당 이자율 계산.
#
# (2000*(1+x)**(1500*24*60*60/12)-2000) * 30000000 / 130000000 = 30001605 - 30000000



def f(x):
    return (2000 * (1+x) ** (1500*24*60*5) - 2000) * 3 / 13 - 1605

def bisection_method(a, b, tol):
    while (b - a) / 2.0 > tol:
        midpoint = (a + b) / 2.0
        if f(midpoint) == 0:
            return midpoint
        elif f(a) * f(midpoint) < 0:
            b = midpoint
        else:
            a = midpoint
    return (a + b) / 2.0

# 초기 값 설정
a = 0
b = 0.0001

tolerance = 1e-21

# 근사값 계산
approx_solution = bisection_method(a, b, tolerance)

# 결과 출력
print(f"x ≈ {approx_solution:.33f}")

# x ≈ 0.000000138802311089315088974755668, 오차 약간 수정해서 0.000000138822311089315088974755668 로 수정